# -*- perl -*-
use strict;
use warnings;
use Path::Tiny;
use Wanage::HTTP;
use Warabe::App;
use Promise;
use Promised::File;
use JSON::PS;
use Web::UserAgent::Functions qw(http_get);
use Web::URL::Canonicalize qw(url_to_canon_url);
use Web::XML::Parser;
use Web::DOM::Document;
use Web::Feed::Parser;

$ENV{LANG} = 'C';
$ENV{TZ} = 'UTC';

$Wanage::HTTP::UseXForwardedScheme = 1;

my $RootPath = path (__FILE__)->parent->parent;
sub static ($$$) {
  my ($app, $type, $name) = @_;
  $app->http->set_response_header ('Content-Type' => $type);
  my $file = Promised::File->new_from_path ($RootPath->child ($name));
  return $file->stat->then (sub {
    $app->http->set_response_last_modified ($_[0]->mtime);
    return $file->read_byte_string;
  })->then (sub {
    $app->http->send_response_body_as_ref (\($_[0]));
    $app->http->close_response_body;
  });
} # static

sub main ($$) {
  my ($class, $app) = @_;
  my $path = $app->path_segments;

  if (@$path == 1 and $path->[0] eq '') {
    # /
    return static $app, 'text/html; charset=utf-8', 'index.html';
  }

  if (@$path == 1 and $path->[0] eq 'css') {
    # /css
    return static $app, 'text/css; charset=utf-8', 'css.css';
  }

  if (@$path == 1 and $path->[0] eq 'viewer') {
    # /viewer
    $app->requires_request_method ({POST => 1});
    my $url = $app->text_param ('url') // '';
    $url = url_to_canon_url $url;
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      unless ($url =~ m{^https?://}) {
        return $ng->({error => "Bad |url|: |$url|"});
      }
      http_get
          url => $url,
          max_redirect => 0,
          timeout => 100,
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->($res);
            } else {
              $ng->({error => "Bad status: |@{[$res->code]}|"});
            }
          };
    })->then (sub {
      my $res = $_[0];
      my $result = {};

      my $doc = new Web::DOM::Document;
      $doc->manakai_set_url ($url);
      my $parser = Web::XML::Parser->new;
      $parser->onerror (sub {
#XXX
      });
      my $charset; # XXX
      $parser->parse_byte_string ($charset, $res->content => $doc);

      my $feeder = Web::Feed::Parser->new;
      my $parsed = $feeder->parse_document ($doc);

      $result->{ok} = 1;
      $result->{url} = $url;
      $result->{parsed} = $parsed;

      $app->http->set_response_header
          ('Content-Type', 'application/json; charset=utf-8');
      local *Web::DateTime::TO_JSON = sub {
        return ['datetime', $_[0]->to_unix_number];
      };
      local *Web::DOM::DocumentFragment::TO_JSON = sub {
        return ['node', $_[0]->inner_html];
      };
      $app->http->send_response_body_as_text (perl2json_chars $result);
      return $app->http->close_response_body;
    })->catch (sub {
      if (ref $_[0] eq 'HASH') {
        $app->http->set_response_header
            ('Content-Type', 'application/json; charset=utf-8');
        $app->http->send_response_body_as_text (perl2json_chars $_[0]);
        return $app->http->close_response_body;
      } else {
        die $_[0];
      }
    });
  }

  return $app->send_error (404);
} # main

return sub {
  ## This is necessary so that different forked siblings have
  ## different seeds.
  srand;

  ## XXX Parallel::Prefork (?)
  delete $SIG{CHLD};
  delete $SIG{CLD};

  my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
  my $app = Warabe::App->new_from_http ($http);

  # XXX accesslog
  warn sprintf "Access: [%s] %s %s\n",
      scalar gmtime, $app->http->request_method, $app->http->url->stringify;

  $http->set_response_header
      ('Strict-Transport-Security' => 'max-age=10886400; includeSubDomains; preload');

  return $app->execute_by_promise (sub {
    return __PACKAGE__->main ($app);
  });
};

=head1 LICENSE

Copyright 2015-2016 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
