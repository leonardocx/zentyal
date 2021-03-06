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

# Class: EBox::Event::Component
#
#  This class incorporates those methods which are common for event
#  architecture components: watchers and dispatchers
#
use strict;
use warnings;

package EBox::Event::Component;

use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::NotImplemented;

# Group: Public methods

# Constructor: new
#
#     Create a <EBox::Event::Component> object instance
#
sub new
{
    my ($class, %args) = @_;

    my $self = {};
    bless($self, $class);

    return $self;
}

# Method: name
#
#       Accessor to the event component identifier. If
#       <EBox::Event::Component::_name> is not overridden, the
#       class name is returned.
#
# Returns:
#
#       String - the unique name
#
sub name
{
    my ($self) = @_;

    my $componentEventName = $self->_name();

    return $componentEventName;
}

# Method: ConfigurationMethod
#
#       Class method which determines which kind of method is used in
#       order to select which kind of configuration will be used. This
#       method should be overridden. *(Abstract)*
#
# Returns:
#
#       String - one of the following:
#           - link - if the configuration is done via URL
#           - model - if the configuration is done via Model
#           - none - if no configuration is required
#
sub ConfigurationMethod
{
    throw EBox::Exceptions::NotImplemented();
}

# Method: ConfigureURL
#
#       Get the configuration URL to set the configuration. Static
#       method.
#
# Returns:
#
#       String - the URL where to set the configuration
#
sub ConfigureURL
{
    throw EBox::Exceptions::NotImplemented();
}

# Method: ConfigureModel
#
#       Get the configuration model to set the dispatcher
#       configuration. Static method.
#
# Returns:
#
#       String - the model which describe the configuration
#
sub ConfigureModel
{
    throw EBox::Exceptions::NotImplemented();
}

# Method: DisabledByDefault
#
#   This method is used to enable or disable the component
#   when is added to a table for first time.
#
#   Returns true by default. That means the component will be disabled
#
# Returns:
#
#       Boolean - indicating if it's disabled by default or not
#
sub DisabledByDefault
{
    return 1;
}

# Method: EditableByUser
#
#       Check if the given event component is editable
#       (enable/disable) by user or only by eBox code
#
# Returns:
#
#       Boolean - indicating if editable by user or not
#
sub EditableByUser
{
    return 1;
}

# Group: Protected methods

# Method: _name
#
#      The i18ned method to name the event watcher. To be
#      overridden by subclasses.
#
# Returns:
#
#      String - the name. Default value: the class name
#
sub _name
{
    my ($self) = @_;

    # Default, return the class name
    return ref ( $self );
}

1;
