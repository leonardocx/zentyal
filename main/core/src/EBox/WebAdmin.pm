# Copyright (C) 2008-2014 Zentyal S.L.
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

package EBox::WebAdmin;
use base qw(EBox::Module::Service EBox::HAProxy::ServiceBase);

use EBox;
use EBox::Validate qw( checkPort checkCIDR );
use EBox::Sudo;
use EBox::Global;
use EBox::Service;
use EBox::Menu;
use EBox::Exceptions::InvalidData;
use EBox::Exceptions::InvalidType;
use EBox::Exceptions::Internal;
use EBox::Exceptions::DataExists;
use EBox::Exceptions::DataMissing;
use EBox::Exceptions::DataNotFound;
use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::External;
use EBox::Gettext;
use EBox::Config;
use EBox::Util::Version;
use English qw(-no_match_vars);
use File::Basename;
use File::Slurp;
use POSIX qw(setsid setlocale LC_ALL);
use TryCatch::Lite;

# Constants
use constant NGINX_INCLUDE_KEY => 'nginxIncludes';
use constant NGINX_SERVER_KEY => 'nginxServers';
use constant CAS_KEY => 'cas';
use constant CA_CERT_PATH  => EBox::Config::conf() . 'ssl-ca/';
use constant CA_CERT_FILE  => CA_CERT_PATH . 'nginx-ca.pem';
use constant NO_RESTART_ON_TRIGGER => EBox::Config::tmp() . 'webadmin_no_restart_on_trigger';

# Constructor: _create
#
#      Create a new EBox::WebAdmin module object
#
# Returns:
#
#      <EBox::WebAdmin> - the recently created model
#
sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(
        name   => 'webadmin',
        printableName => __('Zentyal Webadmin'),
        @_
    );

    bless($self, $class);
    return $self;
}

sub serverroot
{
    return '/var/lib/zentyal';
}

# FIXME: is this still needed?
# Method: cleanupForExec
#
#   It does the job to prepare a forked apache process to do an exec.
#   We should use spawn_proc_prog() from mod_perl but we experience
#   some issues.
#
#
sub cleanupForExec
{
    POSIX::setsid();

    opendir(my $dir, "/proc/$$/fd");
    while (defined(my $fd = readdir($dir))) {
        next unless ($fd =~ /^\d+$/);
        eval('POSIX::close($fd)');
    }
    open(STDOUT, '> /dev/null');
    open(STDERR, '> /dev/null');
    open(STDIN, '/dev/null');
}

sub _daemon
{
    my ($self, $action) = @_;

    $self->_manageNginx($action);

    if ($action eq 'stop') {
        # Stop redis server
        $self->{redis}->stopRedis();
        $self->setHardRestart(0) if $self->hardRestart();
    }
}

sub _manageNginx
{
    my ($self, $action) = @_;

    EBox::Service::manage($self->_uwsgiUpstartName(), $action);
    EBox::Service::manage($self->_nginxUpstartName(), $action);
}

sub setHardRestart
{
    my ($self, $reload) = @_;
    my $state = $self->get_state;
    $state->{hardRestart} = $reload;
    $self->set_state($state);
}

# return wether we should reload the page after saving changes
sub hardRestart
{
    my ($self) = @_;
    my $state = $self->get_state;
    return $state->{hardRestart};
}

# Method: listeningPort
#
#     Return the listening port for the webadmin.
#
#     Just call <EBox::HAProxy::ServiceBase::listeningHTTPSPort>
#
# Returns:
#
#     Int - the listening port
#
sub listeningPort
{
    my ($self) = @_;
    return $self->listeningHTTPSPort();
}

sub _stopService
{
    my ($self) = @_;

    $self->_daemon('stop');
}

sub _setConf
{
    my ($self) = @_;

    $self->_setLanguage();
    $self->_writeNginxConfFile();
    $self->_writeCSSFiles();
    $self->_reportAdminPort();
    $self->enableRestartOnTrigger();

    my $apportEnabled = 0;
    if (EBox::Config::boolean('debug')) {
        my $sysinfo = EBox::Global->modInstance('sysinfo');
        $apportEnabled = $sysinfo->model('Debug')->value('enabled');
    }
    EBox::Sudo::root("sed -i 's/^enabled=.*/enabled=$apportEnabled/' /etc/default/apport");
}

sub _enforceServiceState
{
    my ($self) = @_;

    $self->_daemon('restart');

    EBox::Sudo::silentRoot('service apport restart');
}

sub _nginxConfFile
{
    return '/var/lib/zentyal/conf/nginx.conf';
}

sub _nginxUpstartName
{
    return 'zentyal.webadmin-nginx';
}

sub _nginxUpstartFile
{
    my ($self) = @_;

    my $nginxUpstartName = $self->_nginxUpstartName();
    return "/etc/init/$nginxUpstartName.conf";
}

sub _uwsgiUpstartName
{
    return 'zentyal.webadmin-uwsgi';
}

sub _uwsgiUpstartFile
{
    my ($self) = @_;

    my $uwsgiUpstartName = $self->_uwsgiUpstartName();
    return "/etc/init/$uwsgiUpstartName.conf";
}

sub _writeNginxConfFile
{
    my ($self) = @_;

    my $nginxconf = $self->_nginxConfFile();
    my $templateConf = 'core/nginx.conf.mas';

    my @confFileParams = ();
    push @confFileParams, (bindaddress         => $self->targetIP());
    push @confFileParams, (port                => $self->targetHTTPSPort());
    push @confFileParams, (tmpdir              => EBox::Config::tmp());
    push @confFileParams, (zentyalconfdir      => EBox::Config::conf());
    push @confFileParams, (includes            => $self->_nginxIncludes(1));
    push @confFileParams, (servers             => $self->_nginxServers(1));
    push @confFileParams, (restrictedresources => $self->get_list('restricted_resources') );

    my $permissions = {
        uid => EBox::Config::user(),
        gid => EBox::Config::group(),
        mode => '0644',
        force => 1,
    };

    EBox::Module::Base::writeConfFileNoCheck($nginxconf, $templateConf, \@confFileParams, $permissions);

    @confFileParams = ();
    push @confFileParams, (conf => $self->_nginxConfFile());
    push @confFileParams, (confDir => EBox::Config::conf());

    $permissions = {
        uid => 0,
        gid => 0,
        mode => '0644',
        force => 1,
    };

    EBox::Module::Base::writeConfFileNoCheck($self->_nginxUpstartFile, 'core/upstart-nginx.mas', \@confFileParams, $permissions);

    my $upstartFile = 'core/upstart-uwsgi.mas';
    @confFileParams = ();
    push (@confFileParams, socketpath => '/run/zentyal-' . $self->name());
    push (@confFileParams, socketname => 'webadmin.sock');
    push (@confFileParams, script => EBox::Config::psgi() . 'zentyal.psgi');
    push (@confFileParams, module => $self->printableName());
    push (@confFileParams, user   => EBox::Config::user());
    push (@confFileParams, group  => EBox::Config::group());
    EBox::Module::Base::writeConfFileNoCheck(
        $self->_uwsgiUpstartFile, $upstartFile, \@confFileParams, $permissions);
}

sub _setLanguage
{
    my ($self) = @_;

    my $languageModel = $self->model('Language');

    # TODO: do this only if language has changed?
    my $lang = $languageModel->value('language');
    EBox::setLocale($lang);
    EBox::setLocaleEnvironment($lang);
    EBox::Menu::regenCache();
}

sub _writeCSSFiles
{
    my ($self) = @_;

    my $path = EBox::Config::dynamicwww() . '/css';
    unless (-d $path) {
        mkdir $path;
    }

    my ($primaryGid) = split / /, $GID, 2;

    my $global = EBox::Global->getInstance();
    my $theme = $global->theme();
    my %params = %{ $theme };

    foreach my $file ('public.css', 'login.css', 'jquery-ui.css') {
        my $dst = "$path/$file";
        if ($file eq 'jquery-ui.css') {
            $dst = EBox::Config::www() . '/css/jquery-ui/' . $file;
        }

        EBox::Module::Base::writeConfFileNoCheck($dst,
                                                 "css/$file.mas",
                                                 [ %params ],
                                                 { mode => '0644',
                                                   uid => $UID,
                                                   gid => $primaryGid});
    }

    # special treatment for jqueryui-c


}

# write CA Certificate file with included CAs
sub _writeCAFiles
{
    my ($self) = @_;

    system('rm -rf ' . CA_CERT_PATH);
    mkdir(CA_CERT_PATH);

    foreach my $ca (@{$self->_CAs(1)}) {
        write_file(CA_CERT_FILE, { append => 1 }, read_file($ca));
   }
}

# Report the new TCP admin port to the observer modules
sub _reportAdminPort
{
    my ($self) = @_;

    foreach my $mod (@{$self->global()->modInstancesOfType('EBox::WebAdmin::PortObserver')}) {
        $mod->adminPortChanged($self->listeningHTTPSPort());
    }
}

sub logs
{
    my @logs = ();
    my $log;
    $log->{'module'} = 'webadmin';
    $log->{'table'} = 'access';
    $log->{'file'} = EBox::Config::log . "/access.log";
    my @fields = qw{ host www_user date method url protocol code size referer ua };
    $log->{'fields'} = \@fields;
    $log->{'regex'} = '(.*?) - (.*?) \[(.*)\] "(.*?) (.*?) (.*?)" (.*?) (.*?) "(.*?)" "(.*?)" "-"';
    my @types = qw{ inet varchar timestamp varchar varchar varchar integer integer varchar varchar };
    $log->{'types'} = \@types;
    push(@logs, $log);
    return \@logs;
}

# Method: setRestrictedResource
#
#   Set a restricted resource to the nginx configuration.
#
# Parameters:
#
#   resourceName - String the resource location to restrict.
#   allowedIPs   - Array ref the set of IPs which allow the restricted resource to be accessed in CIDR
#                  format or magic word 'all' or 'nobody'. The former all sources are allowed to see
#                  that resourcename and the latter nobody is allowed to see this resource. 'all'
#                  value has more priority than 'nobody' value.
#
# Exceptions:
#
#   <EBox::Exceptions::MissingArgument> - thrown if any compulsory argument is missing.
#   <EBox::Exceptions::InvalidType>     - thrown if the resource type is invalid.
#   <EBox::Exceptions::Internal>        - thrown if any of the allowed IP addresses are not in CIDR format or no
#                                         allowed IP is given.
#
sub setRestrictedResource
{
    my ($self, $resourceName, $allowedIPs) = @_;

    unless (defined $resourceName) {
        throw EBox::Exceptions::MissingArgument('resourceName');
    }
    unless (defined $allowedIPs) {
        throw EBox::Exceptions::MissingArgument('allowedIPs');
    }

    my $allFound = grep { $_ eq 'all' } @{$allowedIPs};
    my $nobodyFound = grep { $_ eq 'nobody' } @{$allowedIPs};
    if ($allFound) {
        $allowedIPs = ['all'];
    } elsif ($nobodyFound) {
        $allowedIPs = ['nobody'];
    } else {
        # Check the given list is a list of IPs
        my $notIPs = grep { !checkCIDR($_) } @{$allowedIPs};
        if ($notIPs > 0) {
            throw EBox::Exceptions::Internal('Some of the given allowed IP addresses are not in CIDR format');
        }
        if ( @{$allowedIPs} == 0 ) {
            throw EBox::Exceptions::Internal('Some allowed IP must be set');
        }
    }

    my $resources = $self->get_list('restricted_resources');
    if ($self->_restrictedResourceExists($resourceName)) {
        my @deleted = grep { $_->{name} ne $resourceName } @{$resources};
        $resources = \@deleted;
    }
    push (@{$resources}, { name => $resourceName, allowedIPs => $allowedIPs });
    $self->set('restricted_resources', $resources);
}

# Method: delRestrictedResource
#
#   Remove a restricted resource from the list.
#
# Parameters:
#
#   resourcename - String the resource name which indexes which restricted resource is requested to be deleted.
#
# Exceptions:
#
#   <EBox::Exceptions::MissingArgument> - thrown if any compulsory argument is missing.
#   <EBox::Exceptions::DataNotFound>    - thrown if the given resource name is not in the list of restricted
#                                         resources.
#
sub delRestrictedResource
{
    my ($self, $resourcename) = @_;

    unless (defined $resourcename) {
        throw EBox::Exceptions::MissingArgument('resourcename');
    }

    $resourcename =~ s:^/::;

    my $resources = $self->get_list('restricted_resources');

    unless ($self->_restrictedResourceExists($resourcename)) {
        throw EBox::Exceptions::DataNotFound(data => 'resourcename', value => $resourcename);
    }

    my @deleted = grep { $_->{name} ne $resourcename} @{$resources};
    $self->set('restricted_resources', \@deleted);
}

# Method: _restrictedResourceExists
#
#   Whether a restricted resource exists.
#
# Parameters:
#
#   resourcename - String the resource name which we want to check.
#
# Returns:
#
#   Boolean - Whether the given resource is registered or not.
#
sub _restrictedResourceExists
{
    my ($self, $resourcename) = @_;

    foreach my $resource (@{$self->get_list('restricted_resources')}) {
        if ($resource->{name} eq $resourcename) {
            return 1;
        }
    }
    return 0;
}

# Method: isEnabled
#
# Overrides:
#   EBox::Module::Service::isEnabled
sub isEnabled
{
    # apache always has to be enabled
    return 1;
}

# Method: showModuleStatus
#
#   Indicate to ServiceManager if the module must be shown in Module
#   status configuration.
#
# Overrides:
#   EBox::Module::Service::showModuleStatus
#
sub showModuleStatus
{
    # we don't want it to appear in module status
    return undef;
}

# Method: addModuleStatus
#
#   Do not show entry in the module status widget
#
# Overrides:
#   EBox::Module::Service::addModuleStatus
#
sub addModuleStatus
{
}

# Method: addNginxServer
#
#      Add an "server" directive to the nginx configuration. If it is already
#      added, it does nothing
#
# Parameters:
#
#      serverFilePath - String the configuration file path to include
#      in nginx configuration with the server section
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#      <EBox::Exceptions::Internal> - thrown if the given file does
#      not exists
#
sub addNginxServer
{
    my ($self, $serverFilePath) = @_;

    unless(defined($serverFilePath)) {
        throw EBox::Exceptions::MissingArgument('serverFilePath');
    }
    unless(-f $serverFilePath and -r $serverFilePath) {
        throw EBox::Exceptions::Internal(
            "File $serverFilePath cannot be read or it is not a file"
        );
    }
    my @servers = @{$self->_nginxServers(0)};
    unless ( grep { $_ eq $serverFilePath } @servers) {
        push(@servers, $serverFilePath);
        $self->set_list(NGINX_SERVER_KEY, 'string', \@servers);
    }

}

# Method: removeNginxServer
#
#      Remove a "server" directive from the nginx configuration. If the
#      "server" was not in the configuration, it does nothing
#
#
# Parameters:
#
#      serverFilePath - String the configuration file path to remove
#      from nginx configuration
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#
#
sub removeNginxServer
{
    my ($self, $serverFilePath) = @_;

    unless(defined($serverFilePath)) {
        throw EBox::Exceptions::MissingArgument('serverFilePath');
    }
    my @servers = @{$self->_nginxServers(0)};
    my @newServers = grep { $_ ne $serverFilePath } @servers;
    if ( @newServers == @servers ) {
        return;
    }
    $self->set_list(NGINX_SERVER_KEY, 'string', \@newServers);

}

# Return those server files that has been added
sub _nginxServers
{
    my ($self, $check) = @_;
    my $serverList = $self->get_list(NGINX_SERVER_KEY);
    if (not $check) {
        return $serverList;
    }

    my @servers;
    foreach my $servPath (@{ $serverList }) {
        if ((-f $servPath) and (-r $servPath)) {
            push @servers, $servPath;
        } else {
            EBox::warn("Ignoring nginx include server $servPath: cannot read the file or it is not a regular file");
        }
    }

    return \@servers;
}

# Method: addNginxInclude
#
#      Add an "include" directive to the nginx configuration. If it is already
#      added, it does nothing
#
#      Added only in the webadmin server file
#
# Parameters:
#
#      includeFilePath - String the configuration file path to include
#      in nginx configuration
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#
#      <EBox::Exceptions::Internal> - thrown if the given file does
#      not exists
#
sub addNginxInclude
{
    my ($self, $includeFilePath) = @_;

    unless(defined($includeFilePath)) {
        throw EBox::Exceptions::MissingArgument('includeFilePath');
    }
    unless(EBox::Sudo::fileTest('-r', $includeFilePath)) {
        throw EBox::Exceptions::Internal(
            "File $includeFilePath cannot be read or it is not a file"
           );
    }
    my @includes = @{$self->_nginxIncludes(0)};
    unless ( grep { $_ eq $includeFilePath } @includes) {
        push(@includes, $includeFilePath);
        $self->set_list(NGINX_INCLUDE_KEY, 'string', \@includes);
    }

}

# Method: removeNginxInclude
#
#      Remove an "include" directive to the nginx configuration. If the
#      "include" was not in the configuration, it does nothing
#
#
# Parameters:
#
#      includeFilePath - String the configuration file path to remove
#      from nginx configuration
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#
#
sub removeNginxInclude
{
    my ($self, $includeFilePath) = @_;

    unless(defined($includeFilePath)) {
        throw EBox::Exceptions::MissingArgument('includeFilePath');
    }
    my @includes = @{$self->_nginxIncludes(0)};
    my @newIncludes = grep { $_ ne $includeFilePath } @includes;
    if ( @newIncludes == @includes ) {
        return;
    }
    $self->set_list(NGINX_INCLUDE_KEY, 'string', \@newIncludes);

}

# Return those include files that has been added
sub _nginxIncludes
{
    my ($self, $check) = @_;
    my $includeList = $self->get_list(NGINX_INCLUDE_KEY);
    if (not $check) {
        return $includeList;
    }

    my @includes;
    foreach my $incPath (@{ $includeList }) {
        if ((-f $incPath) and (-r $incPath)) {
            push @includes, $incPath;
        } else {
            EBox::warn("Ignoring nginx include $incPath: cannot read the file or it is not a regular file");
        }
    }

    return \@includes;
}

# Method: addCA
#
#   Include the given CA in the ssl_client_certificate
#
# Parameters:
#
#      ca - CA Certificate
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#
#      <EBox::Exceptions::Internal> - thrown if the given file does
#      not exists
#
sub addCA
{
    my ($self, $ca) = @_;

    unless(defined($ca)) {
        throw EBox::Exceptions::MissingArgument('ca');
    }
    unless(-f $ca and -r $ca) {
        throw EBox::Exceptions::Internal(
            "File $ca cannot be read or it is not a file"
           );
    }
    my @cas = @{$self->_CAs(0)};
    unless ( grep { $_ eq $ca } @cas) {
        push(@cas, $ca);
        $self->set_list(CAS_KEY, 'string', \@cas);
    }

}

# Method: removeCA
#
#      Remove a previously added CA from the ssl_client_certificate
#
# Parameters:
#
#       ca - CA certificate
#
# Exceptions:
#
#      <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#      argument is missing
#
#      <EBox::Exceptions::Internal> - thrown if the given file has not
#      been included previously
#
sub removeCA
{
    my ($self, $ca) = @_;

    unless(defined($ca)) {
        throw EBox::Exceptions::MissingArgument('ca');
    }
    my @cas = @{$self->_CAs(0)};
    my @newCAs = grep { $_ ne $ca } @cas;
    if ( @newCAs == @cas ) {
        throw EBox::Exceptions::Internal("$ca has not been included previously",
                                         silent => 1);
    }
    $self->set_list(CAS_KEY, 'string', \@newCAs);
}

# Return those include files that has been added
sub _CAs
{
    my ($self, $check) = @_;
    my $caList = $self->get_list(CAS_KEY);
    if (not $check) {
        return $caList;
    }

    my @cas;
    foreach my $ca (@{ $caList }) {
        if ((-f $ca) and (-r $ca)) {
            push @cas, $ca;
        } else {
            EBox::warn("Ignoring CA $ca: cannot read the file or not is a regular file");
        }
    }

    return \@cas;
}

# Method: certificates
#
#   This method is used to tell the CA module which certificates
#   and its properties we want to issue for this service module.
#
# Returns:
#
#   An array ref of hashes containing the following:
#
#       service - name of the service using the certificate
#       path    - full path to store this certificate
#       user    - user owner for this certificate file
#       group   - group owner for this certificate file
#       mode    - permission mode for this certificate file
#
sub certificates
{
    my ($self) = @_;

    return [
            {
             serviceId =>  'zentyal_' . $self->name(),
             service =>  __('Zentyal Administration Web Server'),
             path    =>  $self->pathHTTPSSSLCertificate(),
             user => EBox::Config::user(),
             group => EBox::Config::group(),
             mode => '0600',
            },
           ];
}

# Method: disableRestartOnTrigger
#
#   Makes webadmin and other modules listed in the restart-trigger script  to
#   ignore it and do nothing
sub disableRestartOnTrigger
{
    system 'touch ' . NO_RESTART_ON_TRIGGER;
    if ($? != 0) {
        EBox::warn('Canot create "webadmin no restart on trigger" file');
    }
}

# Method: enableRestartOnTrigger
#
#   Makes webadmin and other modules listed in the restart-trigger script  to
#   restart themselves when the script is executed (default behaviour)
sub enableRestartOnTrigger
{
    EBox::Sudo::root("rm -f " . NO_RESTART_ON_TRIGGER);
}

# Method: restartOnTrigger
#
#  Whether webadmin and other modules listed in the restart-trigger script  to
#  restart themselves when the script is executed
sub restartOnTrigger
{
    return not EBox::Sudo::fileTest('-e', NO_RESTART_ON_TRIGGER);
}

sub usesPort
{
    my ($self, $proto, $port, $iface) = @_;
    if ($proto ne 'tcp') {
        return 0;
    }
    return $port == $self->listeningHTTPSPort();
}

# Method: initialSetup
#
# Overrides:
#
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Register the service if installing the first time
    unless ($version) {
        my @args = ();
        push (@args, modName        => $self->name);
        push (@args, sslPort        => $self->defaultHTTPSPort());
        push (@args, enableSSLPort  => 1);
        push (@args, defaultSSLPort => 1);
        push (@args, force          => 1);
        my $haproxyMod = $self->global()->modInstance('haproxy');
        $haproxyMod->setHAProxyServicePorts(@args);
    }

    # Upgrade from 3.3
    if (defined ($version) and (EBox::Util::Version::compare($version, '3.4') < 0)) {
        $self->_migrateTo34();
    }
}

# Migration to 3.4
#
#  * Migrate redis keys to use haproxy.
#
sub _migrateTo34
{
    my ($self) = @_;

    my $haproxyMod = $self->global()->modInstance('haproxy');
    my $redis = $self->redis();
    my $key = 'webadmin/conf/AdminPort/keys/form';
    my $value = $redis->get($key);
    unless ($value) {
        # Fallback to the 'ro' version.
        $key = 'webadmin/ro/AdminPort/keys/form';
        $value = $redis->get($key);
    }
    if ($value) {
        if (defined $value->{port}) {
            # There are keys to migrate...
            my @args = ();
            push (@args, modName        => $self->name);
            push (@args, sslPort        => $value->{port});
            push (@args, enableSSLPort  => 1);
            push (@args, defaultSSLPort => 1);
            push (@args, force          => 1);
            $haproxyMod->setHAProxyServicePorts(@args);
        }

        my @keysToRemove = ('webadmin/conf/AdminPort/keys/form', 'webadmin/ro/AdminPort/keys/form');
        $redis->unset(@keysToRemove);
    } else {
        # This case happens when there is no modification on WebAdmin
        my @args = ();
        push (@args, modName        => $self->name);
        push (@args, sslPort        => $self->defaultHTTPSPort());
        push (@args, enableSSLPort  => 1);
        push (@args, defaultSSLPort => 1);
        push (@args, force          => 1);
        $haproxyMod->setHAProxyServicePorts(@args);
    }

    # Migrate the existing zentyal ca definition to follow the new layout used by HAProxy.
    my @caKeys = $redis->_keys('ca/*/Certificates/keys/*');
    foreach my $key (@caKeys) {
        my $value = $redis->get($key);
        unless (ref $value eq 'HASH') {
            next;
        }
        if ($value->{serviceId} eq 'Zentyal Administration Web Server') {
            # WebServer.
            $value->{serviceId} = 'zentyal_' . $self->name();
            $value->{service} = $self->printableName();
            $redis->set($key, $value);
        }
    }
}

#
# Implementation of EBox::HAProxy::ServiceBase
#

# Method: allowServiceDisabling
#
#   Webadmin must be always on so users don't lose access to the web admin UI.
#
# Returns:
#
#   boolean - Whether this service may be disabled from the reverse proxy.
#
sub allowServiceDisabling
{
    return 0;
}

# Method: defaultHTTPSPort
#
# Returns:
#
#   integer - The default public port that should be used to publish this service over SSL or undef if unused.
#
# Overrides:
#
#   <EBox::HAProxy::ServiceBase::defaultHTTPSPort>
#
sub defaultHTTPSPort
{
    return 443;
}

# Method: blockHTTPPortChange
#
#   Always return True to prevent that webadmin is served without SSL.
#
# Returns:
#
#   boolean - Whether the port may be customised or not.
#
sub blockHTTPPortChange
{
    return 1;
}

# Method: pathHTTPSSSLCertificate
#
# Returns:
#
#   string - The full path to the SSL certificate file to use by HAProxy.
#
sub pathHTTPSSSLCertificate
{
    return '/var/lib/zentyal/conf/ssl/ssl.pem';
}

# Method: targetIP
#
# Returns:
#
#   string - IP address where the service is listening, usually 127.0.0.1 .
#
# Overrides:
#
#   <EBox::HAProxy::ServiceBase::targetIP>
#
sub targetIP
{
    return '127.0.0.1';
}

# Method: targetHTTPSPort
#
# Returns:
#
#   integer - Port on <EBox::HAProxy::ServiceBase::targetIP> where the service is listening for SSL requests.
#
# Overrides:
#
#   <EBox::HAProxy::ServiceBase::targetHTTPSPort>
#
sub targetHTTPSPort
{
    return 61443;
}

1;
