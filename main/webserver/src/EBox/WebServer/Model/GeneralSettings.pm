# Copyright (C) 2007 Warp Networks S.L.
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

package EBox::WebServer::Model::GeneralSettings;
use base 'EBox::Model::DataForm';

# Class: EBox::WebServer::Model::GeneralSettings
#
#   Form to set the general configuration settings for the web server.
#

use EBox::Global;
use EBox::Gettext;

use EBox::Types::Port;
use EBox::Types::Boolean;
use EBox::Types::Union;
use EBox::Types::Union::Text;

use EBox::Validate;
use EBox::Exceptions::DataExists;
use EBox::Exceptions::DataNotFound;
use EBox::Exceptions::External;

use TryCatch::Lite;

use constant PUBLIC_DIR => 'public_html';

# Group: Public methods

# Constructor: new
#
#       Create the new GeneralSettings model.
#
# Overrides:
#
#       <EBox::Model::DataForm::new>
#
# Returns:
#
#       <EBox::WebServer::Model::GeneralSettings> - the recently
#       created model.
#
sub new
{
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    bless ( $self, $class );

    return $self;
}

# Method: validateTypedRow
#
# Overrides:
#
#       <EBox::Model::DataTable::ValidateTypedRow>
#
# Exceptions:
#
#       <EBox::Exceptions::DataExists> - if the port number is already
#       in use by any ebox module.
#
sub validateTypedRow
{
    my ($self, $action, $changedFields, $oldFields) = @_;

    if (exists $changedFields->{enableDir} and
        $changedFields->{enableDir}->value())  {
        my $users = EBox::Global->modInstance('users');
        if (not $users) {
            throw EBox::Exceptions::External(
                __('Having installed and configured the Users and Groups module is required to allow HTML directories for users.')
            );
        }
        my $configured = $users->configured();
        if (not $configured) {
            throw EBox::Exceptions::External(
                __('A properly configured Users and Groups module is required to allow HTML directories for users. To configure it, please enable it at least one time.')
            );
        }
    }
}

# Group: Public class static methods

# Method: DefaultEnableDir
#
#     Accessor to the default value for the enableDir field in the
#     model.
#
# Returns:
#
#     boolean - the default value for enableDir field.
#
sub DefaultEnableDir
{
    return 0;
}

# Method: message
#
#   Allows us to introduce some conditionals when showing the message
#
# Overrides:
#
#       <EBox::Model::DataTable::message>
#
#
sub message
{
    my ($self, $action) = @_;
    if ($action eq 'update') {
        my $userstatus = $self->value('enableDir');
        if ($userstatus)  {
            return __('Configuration Settings saved.') . '<br>' .
                   __x('Remember that in order to have UserDir working, you should create the {p} directory, and to provide www-data execution permissions over the involved /home/user directories.', p => PUBLIC_DIR);
        }
    }

    return $self->SUPER::message($action);
}

# Group: Protected methods

# Method: _table
#
#       The table description which consists of:
#
#       enabledDir  - <EBox::Types::Boolean>
#
# Overrides:
#
#      <EBox::Model::DataTable::_table>
#
sub _table
{

    my @tableHeader = (
        new EBox::Types::Boolean(
            fieldName     => 'enableDir',
            printableName => __x('Enable per user {dirName}', dirName => PUBLIC_DIR),
            editable      => 1,
            defaultValue  => EBox::WebServer::Model::GeneralSettings::DefaultEnableDir(),
            help          => __('Allow users to publish web documents using the public_html directory on their home.')
            ),
    );

    my $dataTable = {
       tableName          => 'GeneralSettings',
       printableTableName => __('General configuration settings'),
       defaultActions     => [ 'editField', 'changeView' ],
       tableDescription   => \@tableHeader,
       class              => 'dataForm',
       help               => __x('General Web server configuration. If you enable '
                                 . 'user to publish their own html pages, those should be '
                                 . 'loaded from {dirName} directory from their home directories. If you want to '
                                 . 'change the public ports or enable/disable SSL, you can do it from the '
                                 . '{ohref}System\'s General configuration page{chref}.',
                                 dirName => PUBLIC_DIR,
                                 ohref => '<a href="/SysInfo/Composite/General">',
                                 chref => '</a>'),
       messages           => {
                              update => __('General Web server configuration settings updated.'),
                             },
       modelDomain        => 'WebServer',
    };

    return $dataTable;
}

1;
