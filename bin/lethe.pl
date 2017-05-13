#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;

use AnyEvent;
use AnyEvent::Log; $AnyEvent::Log::FILTER->level("info");
use AnyEvent::HTTP::Server;

use JSON::XS;
our $JSON=JSON::XS->new->utf8;

{ package Lethe::Storage;
	use strict; use warnings;
	use Mouse;

	has _tnt  => (is => 'rw');
	has host => (is => 'rw', required => 1);
	has port => (is => 'rw', required => 1);

	use EV::Tarantool16;

	sub BUILD { my $self = shift;
		$self->{_tnt} = EV::Tarantool16->new({
			host      => $self->{host},
			port      => $self->{port},
			connected => sub {my ($t,$h,$p) = @_;AE::log info => 'Connected tarantool %s:%d', $h, $p},
		});
	}

	sub connect{ my $self = shift; $self->{_tnt}->connect;}

	__PACKAGE__->meta->make_immutable;
	1;
}

{ package Lethe::Injector;
	use strict; use warnings;
	use Mouse;
	has http_server  => (is => 'rw',);
	has http_handler => (is => 'rw',);
	has storage      => (is => 'rw',);
	#has log => (is => 'rw', required => 1);
	has cfg          => (is => 'rw', required => 1);

	use AnyEvent::Socket qw(parse_hostport);
	eval {require Lethe::Storage;};
	use Scalar::Util qw(weaken);

	sub create_objects { my $self = shift;
		$self->create_storage;
		$self->create_http_handler;
		$self->create_http_server;
	}

	sub create_http_server { my $self = shift;
		my ($host, $port) = parse_hostport($self->{cfg}{listen}, 80);
		$self->{http_server} = AnyEvent::HTTP::Server->new(
			host => $host,
			port => $port,
			cb => sub { my $r = shift;
				$self->{http_handler}->body_reader($r);
			}
		);
	}

	sub create_storage { my $self = shift;
		my ($host, $port) = parse_hostport($self->{cfg}{storage}, 3301);
		$self->{storage} = Lethe::Storage->new(
			host => $host,
			port => $port,
		);
	}

	sub create_http_handler { my $self = shift;
		my $inj = weaken($self);
		$self->{http_handler} = Lethe::HttpHandler->new(
			inj => $inj,
		);
	}

	__PACKAGE__->meta->make_immutable;
	1;
}


{ package Lethe::Ctx;
	use strict; use warnings;
	use Mouse;
	use Time::HiRes qw(time);

	has inj         => (is => 'rw', required => 1);
	has post_params => (is => 'rw', default => sub{ {} });
	has body        => (is => 'rw', default => '');
	has _started    => (is => 'rw', default => time());
	has _finished   => (is => 'rw', default => time(), lazy => 1);
	has cb          => (is => 'rw');

	sub duration{my $self = shift; $self->_finished - $self->_started}

	sub reply{ my $self = shift;
		#return unless $self->{req};
		delete($self->{cb})->(@_) if $self->{cb};
	}

	sub DESTROY { my $self = shift;
		return unless $self;
		#delete $self->{req};
		delete $self->{post_params};
		delete $self->{body};
		AE::log error => 'CONTEXT DESTROY WITH CB' if delete $self->{cb};
	}
}

{ package Lethe::HttpHandler;
	use strict; use warnings;
	use Mouse;
	use Data::Dumper;
	#use URI::Escape::XS;
	use URL::Encode qw(url_params_mixed);
	use HTML::Entities qw(decode_entities);
	use Carp;

	has inj => (is => 'rw', required => 1);

	sub body_reader{ my $self = shift;
		my $r = shift;
		#AE::log error => 'body_reader start';
		if ($r->method eq 'POST') {
			$self->form_data_helper($r);
		} elsif ($r->method eq 'PUT') {
			$self->body_reader_helper($r);
		} else {
			$self->dispatch($r);
		}
	}

	sub form_data_helper{ my $self = shift;
		my $r    = shift;
		return {
			form => sub {
				my $body = pop;
				$self->dispatch($r, $body);
			}
		};
	}

	sub body_reader_helper{ my $self = shift;
		#AE::log error => 'body_reader_helper enter';
		my $r = shift;
		my $body = '';
		my $i =0;
		return  sub {
			my ($is_last, $part) = (shift, shift);
			#AE::log error => 'body_reader_helper CB %s', $i++;
			$body .= $$part;
			if (length $body > 2<<13) {
				$r->replyjs(400, {error => 1, reason => 'Body to long'});
				return;
			}
			$self->dispatch($r, $body) if $is_last;
		};
	}

	sub decode_query { my $self = shift;
		my $query  = shift or croak 'Need query to decode';
		my $params = url_params_mixed($query);
		for (keys %$params) {
			#$msg = encode('UTF-8', $msg);
			#utf8::decode($params->{$_});
			$params->{$_} = decode_entities($params->{$_});
		}
		return $params;
	}

	sub dispatch{ my $self = shift;
		my $r           = shift;
		my $body        = (shift)//'';
		my $post_params = $self->decode_query($body);
		#AE::log error => 'Params: %s', $post_params->{message};
		my $ctx = Lethe::Ctx->new(
			inj         => $self->{inj},
			post_params => $post_params,
			body        => $body,
			cb          => sub {$r->replyjs(200, {success=>1})},
		);

		$ctx->reply(200, {error => 0, reason => 'OK'});
		#AE::log error => 'Called ctx->reply';
		return;
	}

	__PACKAGE__->meta->make_immutable;

	1;
}


{ package Lethe::Application;
	use strict; use warnings;
	use Mouse;
	has inj => (is => 'rw', required => 1);
	has cv => (is => 'rw', default => sub{AE::cv});

	sub run{ my $self = shift;
		$self->{inj}->create_objects;
		$self->{inj}{storage}->connect;
		$self->{inj}{http_server}->listen;
		$self->{inj}{http_server}->accept;
		AE::log info => 'Listening http://%s:%d', @{$self->{inj}{http_server}}{qw(host port)};
		return $self->{cv};
	};

	__PACKAGE__->meta->make_immutable;

	1;
}


my $cfg = {
	listen  => '127.0.0.1:16000',
	storage => '127.0.0.1:15000',
};

#my $log = { };

my $inj = Lethe::Injector->new(
	cfg => $cfg,
	#log => $log,
);

my $app = Lethe::Application->new(
	inj => $inj,
);
my $cv = $app->run;
$cv->recv;
AE::log info => "Exiting";

