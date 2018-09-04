# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2015 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

package RT::Dashboard::Mailer;
use strict;
use warnings;
no warnings 'redefine';

use RT::Interface::CLI qw( loc );

sub SendDashboard {
    my $self = shift;
    my %args = (
        CurrentUser  => undef,
        Email        => undef,
        Subscription => undef,
        DryRun       => 0,
        @_,
    );

    my $currentuser  = $args{CurrentUser};
    my $subscription = $args{Subscription};

    my $rows = $subscription->SubValue('Rows');

    my $DashboardId = $subscription->SubValue('DashboardId');

    my $dashboard = RT::Dashboard->new($currentuser);
    my ($ok, $msg) = $dashboard->LoadById($DashboardId);

    # failed to load dashboard. perhaps it was deleted or it changed privacy
    if (!$ok) {
        $RT::Logger->warning("Unable to load dashboard $DashboardId of subscription ".$subscription->Id." for user ".$currentuser->Name.": $msg");
        return $self->ObsoleteSubscription(
            %args,
            Subscription => $subscription,
        );
    }

    $RT::Logger->debug('Generating dashboard "'.$dashboard->Name.'" for user "'.$currentuser->Name.'":');

    if ($args{DryRun}) {
        print << "SUMMARY";
    Dashboard: @{[ $dashboard->Name ]}
    User:   @{[ $currentuser->Name ]} <$args{Email}>
SUMMARY
        return;
    }

    local $HTML::Mason::Commands::session{CurrentUser} = $currentuser;
    local $HTML::Mason::Commands::r = RT::Dashboard::FakeRequest->new;

    my $content;
    my @attachments;
    my $send_msexcel = $subscription->SubValue('MSExcel');

    if ( $send_msexcel
         and $send_msexcel eq 'selected') { # Send reports as MS Excel attachments?

        $RT::Logger->debug("Generating MS Excel reports for dashboard " . $dashboard->Name);

        $content = "<p>" . loc("Scheduled reports are attached for dashboard ")
        . $dashboard->Name . "</p>";

        my @searches = $dashboard->Searches();

        # Run each search and push the resulting file into the @attachments array
        foreach my $search (@searches){
            my $search_content = $search->{'Attribute'}->Content;

            my $xlsx = RunComponent(
                '/Search/Results.xlsx',
                'Query'   => $search_content->{'Query'} || '',
                'Order'   => $search_content->{'Order'} || '',
                'OrderBy' => $search_content->{'OrderBy'} || '',
                'Format'  => $search_content->{'Format'} || '',
            );

            # Grab Name for RT System saved searches
            my $search_name = $search->{'Attribute'}->Name;

            # Use Description for user generated saved searches
            $search_name = $search->{'Attribute'}->Description if $search_name eq 'SavedSearch';

            push @attachments, {
                Content  => $xlsx,
                Filename => $search_name . '.xlsx',
                Type     => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            };
        }
    }
    else{
        # Process standard inline dashboard
        $content = RunComponent(
            '/Dashboards/Render.html',
            id      => $dashboard->Id,
            Preview => 0,
        );

        if ( RT->Config->Get('EmailDashboardRemove') ) {
            for ( RT->Config->Get('EmailDashboardRemove') ) {
                $content =~ s/$_//g;
            }
        }

        $content = ScrubContent($content);

        $RT::Logger->debug("Got ".length($content)." characters of output.");

        $content = HTML::RewriteAttributes::Links->rewrite(
            $content,
            RT->Config->Get('WebURL') . 'Dashboards/Render.html',
        );
    }

    $self->EmailDashboard(
        %args,
        Dashboard => $dashboard,
        Content   => $content,
        Attachments => \@attachments,
    );
}

sub BuildEmail {
    my $self = shift;
    my %args = (
        Content => undef,
        From    => undef,
        To      => undef,
        Subject => undef,
        Attachments => undef,
        @_,
    );

    my @parts;
    my %cid_of;

    my $content = HTML::RewriteAttributes::Resources->rewrite($args{Content}, sub {
            my $uri = shift;

            # already attached this object
            return "cid:$cid_of{$uri}" if $cid_of{$uri};

            my ($data, $filename, $mimetype, $encoding) = GetResource($uri);
            return $uri unless defined $data;

            $cid_of{$uri} = time() . $$ . int(rand(1e6));

            # Encode textual data in UTF-8, and downgrade (treat
            # codepoints as codepoints, and ensure the UTF-8 flag is
            # off) everything else.
            my @extra;
            if ( $mimetype =~ m{text/} ) {
                $data = Encode::encode( "UTF-8", $data );
                @extra = ( Charset => "UTF-8" );
            } else {
                utf8::downgrade( $data, 1 ) or $RT::Logger->warning("downgrade $data failed");
            }

            push @parts, MIME::Entity->build(
                Top          => 0,
                Data         => $data,
                Type         => $mimetype,
                Encoding     => $encoding,
                Disposition  => 'inline',
                Name         => RT::Interface::Email::EncodeToMIME( String => $filename ),
                'Content-Id' => $cid_of{$uri},
                @extra,
            );

            return "cid:$cid_of{$uri}";
        },
        inline_css => sub {
            my $uri = shift;
            my ($content) = GetResource($uri);
            return defined $content ? $content : "";
        },
        inline_imports => 1,
    );

    my $entity = MIME::Entity->build(
        From    => Encode::encode("UTF-8", $args{From}),
        To      => Encode::encode("UTF-8", $args{To}),
        Subject => RT::Interface::Email::EncodeToMIME( String => $args{Subject} ),
        Type    => "multipart/mixed",
    );

    $entity->attach(
        Type        => 'text/html',
        Charset     => 'UTF-8',
        Data        => Encode::encode("UTF-8", $content),
        Disposition => 'inline',
        Encoding    => "base64",
    );

    for my $part (@parts) {
        $entity->add_part($part);
    }

    $entity->make_singlepart;

    if ( defined $args{'Attachments'} and @{$args{'Attachments'}} ){
        foreach my $attachment (@{$args{'Attachments'}}){
            $entity->attach(
                Type        => $attachment->{'Type'},
                Data        => $attachment->{'Content'},
                Filename    => $attachment->{'Filename'},
                Disposition => 'attachment',
            );
        }
    }

    return $entity;
}

1;

