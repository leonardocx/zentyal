# Copyright (C) 2007 Warp Networks S.L.
# Copyright (C) 2008-2013 Zentyal S.L.
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

package EBox::Event::Dispatcher::Log;

use base 'EBox::Event::Dispatcher::Abstract';

# Class: EBox::Dispatcher::Log
#
# This class is a dispatcher which sends the event to the eBox log.
#

################
# Dependencies
################
use Data::Dumper;

use EBox;
use EBox::Gettext;
use EBox::Exceptions::MissingArgument;

use constant LOG_FILE => EBox::Config::log() . 'events.log';

# Group: Public methods

# Constructor: new
#
#        The constructor for <EBox::Event::Dispatcher::Log>
#
#
# Returns:
#
#        <EBox::Event::Dispatcher::Log> - the newly created object
#
sub new
{
    my ($class) = @_;

    my $self = $class->SUPER::new('ebox');
    bless ($self, $class);

    return $self;
}

# Method: DisabledByDefault
#
#   Overrides <EBox::Event::Component::DisabledByDefault>
#   to enable it by default
#
sub DisabledByDefault
{
    return 0;
}

# Method: EditableByUser
#
#   Overrides <EBox::Event::Componet::EditableByUser>
#   to not allow the user to disable it
sub EditableByUser
{
    return 0;
}

# Method: ConfigurationMethod
#
# Overrides:
#
#       <EBox::Event::Dispatcher::Abstract::ConfigurationMethod>
#
sub ConfigurationMethod
{
    return 'none';
}

# Method: configured
#
# Overrides:
#
#        <EBox::Event::Dispatcher::Abstract::configured>
#
sub configured
{
    return 'true';
}

# Method: send
#
#        Send the event to the eBox log system
#
# Overrides:
#
#        <EBox::Event::Dispatcher::Abstract::send>
#
sub send
{
    my ($self, $event) = @_;

    defined ($event) or
        throw EBox::Exceptions::MissingArgument('event');

    open (my $logfile, '>>', LOG_FILE);

    my $timestamp = POSIX::strftime("%d/%m/%Y %H:%M:%S",
                                    localtime(EBox::Event::timestamp($event)));
    my $debug = EBox::Config::boolean('debug');

    #Print the event into the log file
    print $logfile "$timestamp ";
    if (defined $event->{duration}) {
        print $logfile '(' . $event->{duration} . ' s) ';
    }
    print $logfile uc($event->{level}) . '> ' . $event->{source};
    if ($debug && defined $event->{dispatchers}) {
        print $logfile '->[';

        my $count = 0;
        for my $disp (@{$event->{dispatchers}}) {
            $count++;
            print $logfile ($count>1 ? ',' : '' ) . "'$disp'";
        }

        print $logfile ']';
    }
    print $logfile ': ' . $event->{message};
    if ($debug && defined $event->{compMessage}) {
        print $logfile ' (compMessage: ' . $event->{compMessage} . ')';
    }
    print $logfile "\n";

    close ($logfile);

    return 1;
}

# Group: Protected methods

# Method: _receiver
#
# Overrides:
#
#       <EBox::Event::Dispatcher::Abstract::_receiver
#
sub _receiver
{
    return __('Log file');
}

# Method: _name
#
# Overrides:
#
#       <EBox::Event::Dispatcher::Abstract::_name>
#
sub _name
{
    return __('Log');
}

1;
