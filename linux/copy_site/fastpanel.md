Description
FASTPANEL provides a command-line interface (CLI) implemented through the mogwai utility (/usr/local/bin/mogwai). The utility will only work when run as root.

Help
To see a list of available commands, use:

mogwai --help

To learn more about a specific command, use:

mogwai command --help

To see a list of commands with descriptions, use:

mogwai --help-long

Websites
Listing sites on a server
Command

mogwai sites list

Example output

ID      SERVER_NAME             ALIASES                         OWNER                   MODE    PHP_VERSION     IPS             DOCUMENT_ROOT
1       example.com             www.example.com                 example_com_usr         mpm_itk 82              127.0.0.1   /var/www/example_com_usr/data/www/example.com


Note: Site IDs from this list are used in other commands.

Creating a new site
Command

mogwai sites create --server-name=SERVER-NAME --owner=OWNER [<flags>]

Options

--owner : User on the FASTPANEL system who will own the site.
--server-name=SERVER-NAME : Domain name for the site.
-a, --alias=ALIAS : Aliases for the site, such as www subdomains. Multiple aliases can be specified.
--ip=IP : IP address of the server where the site will run. Multiple IP addresses can be specified.
-h, --handler=HANDLER : Backend handler. Can be:
PHP: cgi,mpm_itk,php_fpm,fcgi;
Node.js: standalone,pm2;
Systemd: systemd.
--handler_version=HANDLER_VERSION : PHP or Node.js version (e.g. 8.2, 8.3, 20.15.1).
--create-user : Create a user for the site.
Example command

mogwai sites create --server-name=example.com --owner=user --create-user --alias=www.example.com --ip=127.0.0.1 --handler=fcgi --handler_version=7.3


Deleting a site
Command

mogwai sites delete --id=ID

The site ID can be obtained from the mogwai sites list command.

Example command

mogwai sites delete --id=987

This command will delete site with ID 987

Modifying site settings
Command

mogwai sites update --id=ID [<flags>]

The site ID can be obtained from the mogwai sites list command.

Options

-i, --id=ID : ID of the site.
-a, --add-alias=ADD-ALIAS : Add an alias, multiple aliases can be specified.
--del-alias=DEL-ALIAS : Delete an alias, multiple aliases can be specified.
--add-ip=ADD-IP : Add an IP address from the site settings, multiple IP addresses can be specified.
--del-ip=DEL-IP : Delete an IP address from the site settings, multiple IP addresses can be specified.
-h, --handler=HANDLER : Backend handler. Can be:
PHP: cgi,mpm_itk,php_fpm,fcgi;
Node.js: standalone,pm2;
Systemd: systemd.
--handler_version=HANDLER_VERSION : PHP or Node.js version (e.g. 8.2, 8.3, 20.15.1).
--gzip : Enable compression.
--no-gzip : Disable compression.
--gzip-comp-level=LEVEL : Set the compression level, 1-9.
--expires=EXPIRES : Set the caching time for static content.
--worker-count=WORKER-COUNT : Set the number of workers for PHP-FPM
You can also update settings for multiple sites on a server using the command

mogwai sites batch-update

To change the settings for all sites, use the -a flag.
To change the settings for selected sites, specify multiple --id flags with their IDs.
Example command

mogwai sites update --id=1 -a www1.example.com -h cgi --handler_version=5.6

This command will add an alias www1.example.com, change handler to cgi and PHP Version to 5.6 for site with ID 3

Example command

mogwai sites batch-update -h cgi --handler_version=5.6 --id 3 --id 2

This command will change PHP handler for sites with ID 2 and 3

Databases
Getting a list of database servers
Command

mogwai databases servers list

Example output

ID      NAME                    TYPE            LOCAL   HOST    USERNAME        AVAIL
1       mysql(localhost)        mysql           true            fastuser        true
2       postgresql(localhost)   postgresql      true            fastuser        true

The server IDs is used in other commands.

Getting a list of databases
Command

mogwai databases list

Example output

ID      NAME            SERVER_NAME             LOCAL           HOST    CHARSET OWNER   SIZE    CREATE_AT                              
1       db1             mysql(localhost)        localhost       true    utf8mb4 user    0       2024-05-28 10:03:03.227413266 +0000 UTC
2       database43s     mysql(localhost)        localhost       true    utf8mb4 user82  0       2024-05-28 10:07:15.001640584 +0000 UTC


Synchronizing the database list
If you have recently added or removed databases, and they have not yet appeared in FASTPANEL, you can force synchronization of the lists

Command

mogwai databases sync

Creating a new database
Command

mogwai databases create [flags]

Options

-n, --name=NAME : Database name.
-o, --owner="fastuser" :  FASTPANEL user to whom the database will be added.
-s, --site=SITE : Website in FASTPANEL to which the database will be added.
-c, --charset="utf8mb4" : Database encoding.
-u, --username=USERNAME : Database username.
-p, --password=PASSWORD : Database user password.
Example command

mogwai databases create --server=1 -n db1 -o fastuser -s example.com -u dbuser -p dbpassword1

This command will create a database named db1 on the default database server (--server=1) and "binds" it to the example.com site.

Users
Creating a new user
Command

mogwai users create --username=USERNAME --password=PASSWORD [--role="USER"]

Options

-u, --username=USERNAME : Specify the username for the new user.
-p, --password=PASSWORD : Specify the password for the new user.
-r, --role="USER" : Specify the role for the new user. Supported roles are RESELLER and USER. The default role is USER.
Usage information

To create a new user with the username testuser, password My$ecretPassword123, and role RESELLER, use the following command:

mogwai users create --username=testuser --password=My$ecretPassword123 --role="RESELLER"

Additional notes

Usernames must be unique and cannot contain spaces or dots.
Passwords must be at least 8 characters long. We recommend using at least one uppercase letter, one lowercase letter, one number, and one special character.
Email
Getting a list of email domains
Command

mogwai emails domains list

Example output

ID      NAME            FALLBACK        DKIM    ENABLED OWNER_ID        OWNER           CREATE_AT
1       example.com                     true    true    1               example_com_usr 2024-01-04 15:46:02+03:00

The domains IDs is used in other commands.

Adding an email domain
Command

mogwai emails domains create

Options

--domain=DOMAIN : Email domain name.
-o, --owner="fastuser" : The FASTPANEL user to which the email domain will be added.
Example of creating an email domain example1.com under the fastuser user

mogwai emails domains create --domain=example1.com -o fastuser

Getting a list of mailboxes
Command

mogwai emails boxes list

Options

--domain=DOMAIN : Mail domain name
Example command

mogwai emails boxes list --domain example.com

Example output

ID      ADDRESS                 ALIASES REDIRECTS       SIZE    QUOTA   ENABLED OWNER_ID        OWNER           CREATE_AT
1       user@example.com                                0       0       true    4               example_com_usr 2024-02-08 11:13:01+03:00


The ID from the command output is used in other commands.

Creating a mailbox
Command

mogwai emails boxes create

Options

--domain=DOMAIN : Email domain name.
-l, --login=LOGIN : The name of the mailbox, without the domain.
-p, --password=PASSWORD : The password for the mailbox.
Example command

mogwai emails boxes create  --domain=example.com --login=user --password=MySecretPassword123

This command will create a mailbox named user@example.com with the password MySecretPassword123.

Deleting a mailbox
Command

mogwai emails boxes delete

Options

-b, --box=BOX : The ID of the mailbox..
Example command

mogwai emails boxes delete -b 1

This command will delete the mailbox with the ID of 1.

Importing mailboxes and emails
Command

mogwai emails boxes import[sync] [<flags>]

Options

-i, --import_config=IMPORT_CONFIG : Path to the import list file
--force : Only for import mode - clear existing mailboxes.
To import mail, you need to prepare a list of mailboxes on the server in the format:

IMAP_HOST;SOURCE_ADDR;SOURCE_PASSWORD;DEST_ADDR

Options

IMAP_HOST : Address of the IMAP mail server.
SOURCE_ADDR : Mailbox on the source server.
SOURCE_PASSWORD : Password for IMAP connection to the mailbox on the source server. Some services, such as Google, require creating an application password for IMAP access https://support.google.com/accounts/answer/185833?hl=en
DEST_ADDR : Mailbox on the FASTPANEL server to which messages are transferred.
Example file content

imap.gmail.com;test@gmail.comu;password;test@example.com
imap.gmail.com;test1@gmail.com;password;test1@example.com

Two modes are available:

Import mode

mogwai emails boxes import

In this mode, all messages are copied in full, mailboxes on the FASTPANEL server must not be created or empty - when the command is executed, FASTPANEL creates the necessary mailboxes. If mailboxes with content already exist, an error will be displayed. You can use the --force flag - then the mailbox will be cleared.

Example of running the command with a list of mailboxes stored in the /root/import.txt file and using the --force key

mogwai emails boxes import --import_config=/root/import.txt --force

Sync mode

mogwai emails boxes sync

In this mode, the Control Panel downloads messages from the source server without deleting anything. It should be used if new messages have appeared in the original mailbox after the first import, which also need to be transferred.

Example command

mogwai emails boxes sync --import_config=/root/import.txt

Transferring Users Between FASTPANEL
Introduction
This article describes the process of transferring user accounts and their associated data (websites, databases, email, etc.) from one FASTPANEL server to another using the built-in migration utility.

Key Terms
Source server - The server from which data is being transferred.
Destination server - The server to which data is being transferred.
Important Notes
By default, migration works correctly only for sites with a standard FASTPANEL configuration.

Sites with manual configuration changes can only be transferred if the -m flag is used for IP address mapping.

If an encrypted password for a database owner is not available, the database will not be transferred.

If a website is not transferred, its associated databases will not be transferred either.

Only local databases can be transferred.

Migration Process
Connection
The destination server connects to the source server via SSH. During the first connection, the destination server installs an SSH key on the source server (either pre-provided or generated from a password).

Migration Steps
Module installation
Gathering information about transferable objects
Creating users
Transferring SSL certificates
Creating websites, FTP accounts, email domains, and email accounts
Creating databases and database users
Transferring website and email mailbox files
Transferring cron jobs
File transfer is executed using rsync. Databases are transferred by creating a dump through an SSH tunnel.

Command to Start Migration
The command is run on the destination server as a user with root privileges:

/usr/local/fastpanel2/fastpanel transfer run [SSH_PARAMETERS] [IP_PARAMETERS] [ADDITIONAL_OPTIONS]

Command-line Flags
SSH Connection
--remote_host="SOURCE_IP" - IP address of the source server.
--remote_port="SSH_PORT" - SSH port.
--remote_username="SSH_USER" - User (must be root).
--remote_password="USER_PASSWORD" - Password for the specified SSH user.
--ssh_key_path="PATH_TO_KEY" - Path to the private SSH key on the destination server for connecting to the source server. If a key is used, the password (--remote_password) is not needed.
IP Addresses
You must use only one of the following flags to manage site IP addresses during transfer. The -m flag has priority.

-i "IP_ADDRESS_ON_DESTINATION" - Assigns the specified IP address to all transferred sites on the destination server. To specify multiple IPs (e.g., if there were several on the source), repeat the flag for each source IP that needs to be transferred.

-m "SOURCE_IP,DESTINATION_IP" - Recommended method. Establishes a direct mapping: all sites using SOURCE_IP on the source server will use DESTINATION_IP on the destination server. This flag can be specified multiple times for different IP pairs. Mandatory for transferring sites with manual configuration edits, as it allows correct replacement of IP addresses in listen directives.

Additional Settings
--users="USER_LIST" - Transfers only the specified users (comma-separated). If not specified, all users are transferred.
--disable_disk_quota - Disables the transfer of user disk quotas.
--with_user_data - Includes copying the entire contents of user home directories (except the logs/ subdirectory). Use with caution, as this can significantly increase transfer time and the amount of data transferred.
--only_data - Transfers only data (website files, mail files, database dumps). Useful if the initial structure migration (users, sites, DBs, etc.) was successful, but errors occurred during the file or dump copying stage. Allows rerunning only the data copying part.
--transfer_timeout - Set operation timeout (default is 60 minutes).
Example Command
Transfer all users from server 11.22.33.44 to the current server. On the old server, sites used IPs 11.22.33.44 and 11.22.33.55; on the new server, they should use 99.88.77.66 and 99.88.77.67 respectively. Connection via SSH with a password.

/usr/local/fastpanel2/fastpanel transfer run \
--remote_host=11.22.33.44 \
--remote_username=root \
--remote_password=YourSourceRootPassword \
-m 11.22.33.44,99.88.77.66 \
-m 11.22.33.55,99.88.77.67

Possible Problems and Error Types
An error in the migration log does not always indicate a critical problem but might point to the reason why a specific object was not transferred.

Conflicts: Occur when transferring an object is impossible due to the current configuration of the destination server (e.g., a user or site with the same name already exists) or if the site's configuration on the source server is unknown to the panel (e.g., due to extensive manual edits).

Missing Saved Password: As mentioned earlier, MySQL database users without a saved password in FASTPANEL on the source server cannot be transferred.

Manual Settings and IP Addresses: If a site on the source server has manual web server configuration edits and the -m flag is not used during migration to map its IP address, such a site will not be transferred because the panel does not know which IP to specify in the configuration on the destination server.

