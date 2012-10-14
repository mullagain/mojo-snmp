package Mojo::SNMP::Dispatcher;

=head1 NAME

Mojo::SNMP::Dispatcher - Instead of Net::SNMP::Dispatcher

=cut

use Errno;
use Mojo::Base -base;
use Mojo::IOLoop::Stream;
use Net::SNMP::MessageProcessing();
use Net::SNMP::Message qw( TRUE FALSE );
use Scalar::Util ();
use constant DEBUG => $ENV{MOJO_SNMP_DEBUG} ? 1 : 0;

=head1 ATTRIBUTES

=head2 ioloop

=head2 message_processing

=head2 debug

=head2 error

=cut

has ioloop => sub { Mojo::IOLoop->singleton };
has message_processing => sub { Net::SNMP::MessageProcessing->instance };
has debug => 0; # Use MOJO_SNMP_DEBUG=1 instead

sub connections { int values %{ $_[0]->{descriptors} } }

sub error {
    my($self, $format, @args) = @_;

    return $self->{error} if @_ == 1;
    $self->{error} = defined $format ? sprintf $format, @args : undef;
    warn "[DISPATCHER] $self->{error}\n" if DEBUG and defined $format;
    return $self;
}

=head1 METHODS

=head2 send_pdu

=cut

sub send_pdu {
    my($self, $pdu, $delay) = @_;

    $self->error(undef);

    unless(ref $pdu) {
        $self->error('The required PDU object is missing or invalid');
        return FALSE;
    }

    $self->schedule($delay, [_send_pdu => $pdu, $pdu->retries]);

    return TRUE;
}

=head2 return_response_pdu

=cut

sub return_response_pdu {
    $_[0]->send_pdu($_[1], -1);
}

=head2 msg_handle_alloc

=cut

sub msg_handle_alloc {
    $_[0]->message_processing->msg_handle_alloc;
}

=head2 schedule

=cut

sub schedule {
    my($self, $time, $callback) = @_;
    my $code = shift @$callback;

    Scalar::Util::weaken($self);
    $self->ioloop->timer($time => sub {
        $self->$code(@$callback);
    });
}

=head2 register

=cut

sub register {
    my($self, $transport) = @_;
    my $reactor = $self->ioloop->reactor;
    my $fileno;

    unless(defined $transport and defined($fileno = $transport->fileno)) {
        $self->error('The Transport Domain object is invalid');
        return FALSE;
    }

    if($self->{descriptors}{$fileno}++) {
        return $transport;
    }

    Scalar::Util::weaken($self);
    $reactor->io($transport->socket, sub {
        $self->_transport_response_received($transport);
    });

    $reactor->watch($transport->socket, 1, 0);
    warn "[DISPATCHER] Add handler for descriptor $fileno\n" if DEBUG;
    return $transport;
}

=head2 deregister

=cut

sub deregister {
    my($self, $transport) = @_;
    my $fileno = $transport->fileno;
    return if --$self->{descriptors}{$fileno} > 0;
    delete $self->{descriptors}{$fileno};
    warn "[DISPATCHER] Remove handler for descriptor $fileno\n" if DEBUG;
    $self->ioloop->reactor->remove($transport->socket);
}

#$Net::SNMP::Message::DEBUG = 1;

sub _send_pdu {
    my($self, $pdu, $retries) = @_;
    my $mp = $self->message_processing;
    my $msg = $mp->prepare_outgoing_msg($pdu);

    unless(defined $msg) {
        warn "[DISPATCHER] prepare_outgoing_msg: @{[$mp->error]}\n" if DEBUG;
        $pdu->status_information($mp->error);
        return;
    }
    unless(defined $msg->send) {
        if($pdu->expect_response) {
            $mp->msg_handle_delete($msg->msg_id)
        }
        if($retries-- > 0 and $!{EAGAIN} or $!{EWOULDBLOCK}) {
            warn "[DISPATCHER] Attempt to recover from temporary failure: $!\n" if DEBUG;
            $self->schedule($pdu->timeout, [_send_pdu => $pdu, $retries]);
            return FALSE;
        }

        $pdu->status_information($msg->error);
        return;
    }

    if($pdu->expect_response) {
        $self->register($msg->transport);
        $msg->timeout_id(
            $self->schedule($pdu->timeout, [
                '_transport_timeout',
                $pdu,
                $retries,
                $msg->msg_id,
            ])
        );
    }

    return TRUE;
}

sub _transport_timeout {
    my($self, $pdu, $retries, $handle) = @_;

    $self->deregister($pdu->transport);
    $self->message_processing->msg_handle_delete($handle);

    if($retries-- > 0) {
        warn "[DISPATCHER] Retries left: $retries\n" if DEBUG;
        return $self->_send_pdu($pdu, $retries);
    }
    else {
        warn "[DISPATCHER] No response from remote host @{[ $pdu->hostname ]}\n" if DEBUG;
        $pdu->status_information(q{No response from remote host "%s"}, $pdu->hostname);
        return;
    }
}

sub _transport_response_received {
    my($self, $transport) = @_;
    my $mp = $self->message_processing;
    my($msg, $error) = Net::SNMP::Message->new(-transport => $transport);

    $self->error(undef);

    if(not defined $msg) {
        die sprintf 'Failed to create Message object: %s', $error;
    }
    if(not defined $msg->recv) {
        $self->error($msg->error);
        $self->deregister($transport) unless $transport->connectionless;
        return;
    }
    if(not $msg->length) {
        warn "[DISPATCHER] Ignoring zero length message\n" if DEBUG;
        return;
    }
    if(not $mp->prepare_data_elements($msg)) {
        $self->error($mp->error);
        return;
    }
    if($mp->error) {
        $msg->error($mp->error);
    }

    warn "[DISPATCHER] Processing pdu\n" if DEBUG;
    $self->ioloop->remove($msg->timeout_id);
    $self->deregister($transport);
    $msg->process_response_pdu;
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;