#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;

use AnyEvent;
use AnyEvent::HTTP::Server;

use JSON::XS;
our $JSON=JSON::XS->new->utf8;

{ package Lethe::Storage;
	use strict; use warnings;
	use Mouse;
	use Carp;
	use Data::Dumper;

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

	sub save_message { my $self = shift;
		#AE::log info => 'save_message enter';
		my $cb      = pop or croak 'need callback';
		my $message = shift or croak 'need message';
		#AE::log info => 'save_message arg ok';
		$self->_tnt->lua('app:add_msg', [$message], sub {
			#AE::log info => 'tarantool_result: %s', Dumper \@_;
			my $res = shift;
			my $reply = {error => 0, reason => 'OK'};
			if ($res && ref $res eq 'HASH' && $res->{status} eq 'ok') {
				if (ref $res->{tuples} eq 'ARRAY' && $res->{count} == 1) {
					my $message_id = $res->{tuples}[0][0];
					if (defined $message_id) {
						$reply->{message_id} = $message_id;
					} else {
						$reply->{error} = 1; $reply->{reason} = 'message_id is nil';
					}
				} else {
					$reply->{error} = 1; $reply->{reason} = 'tuples not match expectation';
				}
			} else {
				my $err = shift;
				$err //= $res->{errstr} if ref $res;
				$reply->{error} = 1; $reply->{reason} = $err;
			}
			$cb->($reply);
		});
	}

	sub get_message { my $self = shift;
		#AE::log info => 'save_message enter';
		my $cb         = pop or croak 'need callback';
		my $message_id = shift or croak 'need message';
		#AE::log info => 'save_message arg ok';
		$self->_tnt->lua('app:get_msg', [$message_id], sub {
			my $res = shift;
			my $reply = {error => 0, reason => 'OK', found => 0};
			if ($res && ref $res eq 'HASH' && $res->{status} eq 'ok') {
				if (ref $res->{tuples} eq 'ARRAY' && $res->{count} == 1) {
					my $message = $res->{tuples}[0][0];
					if (defined $message) {
						$reply->{found} = 1;
						$reply->{message} = $message;
					} else {
						$reply->{reason} = 'message not found';
					}
				} else {
					$reply->{error} = 1; $reply->{reason} = 'tuples not match expectation';
				}
			} else {
				my $err = shift;
				$err //= $res->{errstr} if ref $res;
				$reply->{error} = 1; $reply->{reason} = $err;
			}
			$cb->($reply);
		});
	}

	__PACKAGE__->meta->make_immutable;
	1;
}

{ package Lethe::Injector;
	use strict; use warnings;
	use Mouse;
	has http_server  => (is => 'rw',);
	has http_handler => (is => 'rw',);
	has storage      => (is => 'rw',);
	has log          => (is => 'rw', required => 1);
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
		#my $inj = weaken($self);
		$self->{http_handler} = Lethe::HttpHandler->new(
			inj => $self,
		);
	}

	__PACKAGE__->meta->make_immutable;
	1;
}

{ package Lethe::Log;
	use AnyEvent;
	use AnyEvent::Log; $AnyEvent::Log::FILTER->level("info");
	use Mouse;

#	sub new { my $pkg = shift;
#		bless {}, $pkg;
#	}


	sub error { my $self = shift; my $fmt = shift; AE::log error => $fmt, @_; }
	sub info  { my $self = shift; my $fmt = shift; AE::log info => $fmt, @_; }
	sub debug { my $self = shift; my $fmt = shift; AE::log info => $fmt, @_; }


}


{ package Lethe::Ctx;
	use strict; use warnings;
	use Mouse;
	use Time::HiRes qw(time);
	use Data::Dumper;

	has inj         => (is => 'rw', required => 1);
	has post_params => (is => 'rw', default => sub{ {} });
	has get_params  => (is => 'rw', default => sub{ {} });
	has body        => (is => 'rw', default => '');
	has path        => (is => 'rw', default => '');
	has ident       => (is => 'rw', default => '');
	has _started    => (is => 'rw', default => time());
	has _finished   => (is => 'rw', default => time(), lazy => 1);
	has cb          => (is => 'rw');
	has _vsize_start => (is => 'rw', default => current_vsize());
	has _vsize_end   => (is => 'rw', default => current_vsize(), lazy => 1);

	sub current_vsize{
		my $vsize = eval{ open my $f, '<', "/proc/$$/stat" or die $!; (split ' ',<$f>)[22]};
		return $vsize;
	}

	sub mem_stat{ my $self = shift;
		my $vsize = $self->_vsize_start()/1024/1024;
		my $diff  = ($self->_vsize_end - $self->_vsize_start);
		sprintf('%.2f+%d', $vsize, $diff);
	}

	sub duration{my $self = shift; $self->_finished - $self->_started}

	sub reply{ my $self = shift;
		my ($code, $response) = @_;
		my ($log_method, $log_format) = ('info', '%s END=%d D=%.6f V=%s');
		my @log_args = (
			($self->{ident}? sprintf('%s [%s]', $self->path, $self->ident) :$self->path),
			$code,
			$self->duration(),
			$self->mem_stat(),
		);
		unless ($code == 200 && !$response->{error}) {
			($log_method, $log_format) = ('error', '[ERR] %s END=%d D=%.6f V=%s e="%s"');
			my $err = delete @_[2] // $response->{reason} // 'no reason specified';
			push @log_args, $err;
		}
		$self->{inj}{log}->$log_method($log_format, @log_args);
		delete($self->{cb})->(@_) if $self->{cb};
	}

	sub DESTROY { my $self = shift;
		return unless $self;
		#delete $self->{req};
		$self->{post_params} = {};
		$self->{body} = '';
		AE::log error => 'CONTEXT DESTROY WITH CB' if delete $self->{cb};
	}
}

{ package Lethe::HttpHandler;
	use strict; use warnings;
	use Mouse;
	use Data::Dumper;
	#use URI::Escape::XS;
	use URL::Encode qw(url_params_mixed);
	use HTML::Entities qw(decode_entities encode_entities);
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
			$params->{$_} = decode_entities($params->{$_}) if defined $params->{$_};
		}
		return $params;
	}

	sub dispatch{ my $self = shift;
		my $r           = shift;
		my $body        = (shift)//'';
		my $post_params = length($body) > 0 ? $self->decode_query($body) : {};
		my $get_params  = length($r->query) ? $self->decode_query($r->query) : {};
		#AE::log error => 'Params: %s', $post_params->{message};

		my ($handler, $cb) = (undef, sub {$r->replyjs(@_)});
		if ($r->path eq '/msg/add') {
			$handler = 'msg_add';
		} elsif ($r->path =~ m{^/msg/get/([-a-zA-Z_0-9]{1,1024})$}) {
			$handler = 'msg_get';
			$get_params = {message_id => $1};
			$cb = sub { my ($code, $res) = (shift, shift);
				if ($res->{error}) {
					if ($res->{fatal}) {
						$r->reply(200, 'Message not found');
					} else {
						$r->reply(200, 'Temporary error, try again later');
					}
				} else {
					$r->reply(200, $res->{body}//eval{$JSON->encode($res)});
				}
			};

		} else {
			$r->replyjs(500, {error => 'Invalid path'});
			return;
		}

		my $ctx = Lethe::Ctx->new(
			inj         => $self->{inj},
			path        => $r->path(),
			post_params => $post_params,
			get_params  => $get_params,
			body        => $body,
			cb          => $cb,
		);

		$self->$handler($r, $ctx);

		#AE::log error => 'Called ctx->reply';
		return;
	}

	sub msg_add { my $self = shift;
		my $r   = shift or croak 'Need request object';
		my $ctx = shift or croak 'Need context object';
		unless(exists $ctx->{post_params}{message}) {
			$ctx->reply(400, {error => 1, reason => 'message required'});
			return;
		}
		my $message = $ctx->{post_params}{message};
		if (ref $message) {
			$ctx->reply(400, {error => 1, reason => 'message must me string'});
			return;
		}
		unless (length($message) > 0) {
			$ctx->reply(400, {error => 1, reason => 'message length zero'});
			return;
		}
		unless (length($message) <= 4096) {
			$ctx->reply(400, {error => 1, reason => 'max message length exceeded'});
			return;
		}
		#utf8::decode($message);
		$self->{inj}{storage}->save_message($message,sub {
			my $res = shift;
			if ($res->{error}) {
				$ctx->reply(500, {error => 1, reason => 'temporary error', }, $res->{reason});
			} else {
				$ctx->ident(sprintf('%s"',$res->{message_id}));
				$ctx->reply(200, {error => 0, reason => 'OK', message_id => $res->{message_id}});
			}
		});
	}

	sub msg_get { my $self = shift;
		my $r   = shift or croak 'Need request object';
		my $ctx = shift or croak 'Need context object';
		unless(exists $ctx->{get_params}{message_id}) {
			$ctx->reply(400, {error => 1, reason => 'message_id required'});
			return;
		}
		my $message_id = $ctx->{get_params}{message_id};
		if (ref $message_id) {
			$ctx->reply(400, {error => 1, reason => 'message_id must me string'});
			return;
		}
		unless (length($message_id) > 0) {
			$ctx->reply(400, {error => 1, reason => 'message_id length zero'});
			return;
		}
		unless (length($message_id) <= 256) {
			$ctx->reply(400, {error => 1, reason => 'max message_id length exceeded'});
			return;
		}
		unless ($message_id =~ /^[_a-zA-Z-0-9]+$/) {
			$ctx->reply(400, {error => 1, reason => 'message_id invalid'});
			return;
		}
		#$ctx->ident($message_id);
		$self->{inj}{storage}->get_message($message_id,sub {
			my $res = shift;
			if ($res->{error}) {
				$ctx->reply(500, {error => 1, fatal => 0, reason => 'temporary error', }, $res->{reason});
			} elsif ($res->{found}) {
				my $message = $res->{message};
				utf8::decode($message);
				$message = encode_entities($message);
				my $content =<<_EOF;
<!DOCTYPE html>
<html>
<body>
<div>This message may be opened only once. It is already been erased from server</div>
<textarea cols=80 rows=15>$message</textarea>
</body>
</html>
_EOF
				$ctx->reply(200, {error => 0, fatal => 0, reason => 'OK', message => $res->{message}, body => $content});
			} else {
				$ctx->reply(200, {error => 1, fatal => 1, reason => 'not found', message => ''});
			}
		});
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
		$self->inj->log->info('Listening http://%s:%d', @{$self->{inj}{http_server}}{qw(host port)});
		return $self->{cv};
	};

	__PACKAGE__->meta->make_immutable;

	1;
}


use EV;
$EV::DIED = sub {
	warn "EV DIED!!!! $@";
	print "EV DIED!!!! $@\n";
	AE::log error => "EV DIED!!!! $@";
};

my $cfg = {
	listen  => '127.0.0.1:16000',
	storage => '127.0.0.1:15000',
};

#my $log = { };

my $inj = Lethe::Injector->new(
	cfg => $cfg,
	log => Lethe::Log->new(),
);

my $app = Lethe::Application->new(
	inj => $inj,
);
my $cv = $app->run;
$cv->recv;
AE::log info => "Exiting";

