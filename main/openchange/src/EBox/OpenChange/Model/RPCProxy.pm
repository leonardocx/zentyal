# Copyright (C) 2013 Zentyal S. L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

package EBox::OpenChange::Model::RPCProxy;
use base 'EBox::Model::DataForm';

use EBox::Gettext;
use EBox::Types::Text;
use EBox::Types::Link;
use EBox::Types::Boolean;
use TryCatch::Lite;

# Method: new
#
#   Constructor, instantiate new model
#
sub new
{
    my $class = shift;

    my $self = $class->SUPER::new(@_);
    bless ($self, $class);

    return $self;
}

# Method: _table
#
#   Returns model description
#
sub _table
{
    my ($self) = @_;

    my @tableDesc = (
        EBox::Types::Text->new(
            fieldName => 'host',
            printableName => __('Host name'),
            volatile => 1,
            filter => sub { return $self->_host },
            editable => 0,
        ),
        EBox::Types::Link->new(
             fieldName => 'certificate',
             printableName => __('Certificate'),
             volatile  => 1,
             optionalLabel => 0,
             acquirer => sub {
                 my $file = EBox::Config::downloads() . 'rpcproxy.crt';
                 if (not -r $file) {
                     return undef;
                 }
                 return '/Downloader/FromTempDir?filename=rpcproxy.crt';
             },
            HTMLViewer     => '/ajax/viewer/downloadLink.mas',
            HTMLSetter     => '/ajax/viewer/downloadLink.mas',
         ),
        EBox::Types::Boolean->new(
            fieldName     => 'http',
            printableName => __('Access without SSL'),
            defaultValue  => 0,
            editable      => 1
           ),
        EBox::Types::Boolean->new(
            fieldName     => 'https',
            printableName => __('Access with SSL'),
            defaultValue  => 0,
            editable      => 1
           ),
        );

    my $dataForm = {
        tableName          => 'RPCProxy',
        printableTableName => __('HTTP/HTTPS proxy access'),
        modelDomain        => 'OpenChange',
        defaultActions     => [ 'editField' ],
        tableDescription   => \@tableDesc,
        help               => __('Setup access to Openchange throught HTTP/HTTPS. Remember that HTTPS requires you import Zentyal certificate into your Windows account'),
    };

    return $dataForm;
}

sub precondition
{
    my ($self) = @_;
    my $parentModule = $self->parentModule();
    if (not $parentModule->isProvisioned()) {
        $self->{preconditionFailMsg} = '';
        return 0;
    } elsif (not $self->_webserverEnabled()) {
        $self->{preconditionFailMsg} = __('Web Server module needs to be installed and enabled to use RPC proxy');
        return 0;
    }

    my $host;
    try {
        $host = $self->_host();
        if (not $host) {
            $self->{preconditionFailMsg} = __x('Cannot use RPC Proxy because we cannot find this host name in {oh}DNS module{ch}>',
                                               oh => '<a href="/DNS/Composite/Global"',
                                               ch => '</a>'
                                              );
        }
    } catch($ex) {
        $self->{preconditionFailMsg} = __x('Cannot use RPC Proxy because we cannot find this host name: {err}', err => "$ex");
        $host = undef;
    };

    return defined $host;
}

sub preconditionFailMsg
{
    my ($self) = @_;
    return $self->{preconditionFailMsg};
}

sub _host
{
    my ($self) = @_;
    my $hosts = $self->parentModule()->_rpcProxyHosts();
    # for now we have only one host
    return $hosts->[0];
}

sub _webserverEnabled
{
    my ($self) = @_;
    my $webserver = $self->global()->modInstance('webserver');
    if (not $webserver) {
        return 0;
    }
    return $webserver->isEnabled();
}

sub enabled
{
    my ($self) = @_;
    return $self->httpEnabled() or $self->httpsEnabled();
}

sub httpEnabled
{
    my ($self) = @_;
    if (not $self->_webserverEnabled()) {
        return 0;
    }
    return $self->value('http')
}

sub httpsEnabled
{
    my ($self) = @_;
    if (not $self->_webserverEnabled()) {
        return 0;
    }
    return $self->value('https')
}

sub formSubmitted
{
    my ($self, $row, $oldRow) = @_;
    # mark webadmin as changed if the service has changed
    $self->global()->modInstance('haproxy')->setAsChanged();
}

1;
