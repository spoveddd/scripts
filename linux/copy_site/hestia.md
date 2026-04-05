CLI Reference
v-acknowledge-user-notification
Source

update user notification

Options: USER NOTIFICATION

This function updates user notification.

v-add-access-key
Source

generate access key

Options: USER [PERMISSIONS] [COMMENT] [FORMAT]

Examples:


v-add-access-key admin v-purge-nginx-cache,v-list-mail-accounts comment json
The "PERMISSIONS" argument is optional for the admin user only. This function creates a key file in $HESTIA/data/access-keys/

v-add-backup-host
Source

add backup host

Options: TYPE HOST USERNAME PASSWORD [PATH] [PORT]

Examples:


v-add-backup-host sftp backup.acme.com admin 'P4$$w@rD'
v-add-backup-host b2 bucketName keyID applicationKey
Add a new remote backup location. Currently SFTP, FTP and Backblaze are supported

v-add-backup-host-restic
Source

add backup host

Options: TYPE HOST USERNAME PASSWORD [PATH] [PORT]

Examples:


v-add-backup-host sftp backup.acme.com admin 'P4$$w@rD'
v-add-backup-host b2 bucketName keyID applicationKey
Add a new remote backup location. Currently SFTP, FTP and Backblaze are supported

v-add-cron-hestia-autoupdate
Source

add cron job for hestia automatic updates

Options: MODE

This function adds a cronjob for hestia automatic updates that can be downloaded from apt or git.

v-add-cron-job
Source

add cron job

Options: USER MIN HOUR DAY MONTH WDAY CRON_COMMAND [JOB] [RESTART]

Examples:


v-add-cron-job admin * * * * * sudo /usr/local/hestia/bin/v-backup-users
This function adds a job to cron daemon. When executing commands, any output is mailed to user's email if parameter REPORTS is set to 'yes'.

v-add-cron-letsencrypt-job
Source

add cron job for Let's Encrypt certificates

Options: –

This function adds a new cron job for Let's Encrypt.

v-add-cron-reports
Source

add cron reports

Options: USER

Examples:


v-add-cron-reports admin
This function for enabling reports on cron tasks and administrative notifications.

v-add-cron-restart-job
Source

add cron reports

Options: –

This function for enabling restart cron tasks

v-add-database
Source

add database

Options: USER DATABASE DBUSER DBPASS [TYPE] [HOST] [CHARSET]

Examples:


v-add-database admin wordpress_db matt qwerty123
This function creates the database concatenating username and user_db. Supported types of databases you can get using v-list-sys-config script. If the host isn't stated and there are few hosts configured on the server, then the host will be defined by one of three algorithms. "First" will choose the first host in the list. "Random" will chose the host by a chance. "Weight" will distribute new database through hosts evenly. Algorithm and types of supported databases is designated in the main configuration file.

v-add-database-host
Source

add new database server

Options: TYPE HOST DBUSER DBPASS [MAX_DB] [CHARSETS] [TEMPLATE] [PORT]

Examples:


v-add-database-host mysql localhost alice p@$$wOrd
This function add new database server to the server pool. It supports local and remote database servers, which is useful for clusters. By adding a host you can set limit for number of databases on a host. Template parameter is used only for PostgreSQL and has an default value "template1". You can read more about templates in official PostgreSQL documentation.

v-add-database-temp-user
Source

add temp database user

Options: USER DATABASE [TYPE] [HOST] [TTL]

Examples:


v-add-database-temp-user wordress wordpress_db mysql
This function creates an temporary database user mysql_sso_db_XXXXXXXX and a random password The user has an limited validity and only granted access to the specific database Returns json to be read SSO Script

v-add-dns-domain
Source

add dns domain

Options: USER DOMAIN IP [NS1] [NS2] [NS3] [NS4] [NS5] [NS6] [NS7] [NS8] [RESTART]

Examples:


v-add-dns-domain admin example.com ns1.example.com ns2.example.com '' '' '' '' '' '' yes
This function adds DNS zone with records defined in the template. If the exp argument isn't stated, the expiration date value will be set to next year. The soa argument is responsible for the relevant record. By default the first user's NS server is used. TTL is set as common for the zone and for all of its records with a default value of 14400 seconds.

v-add-dns-on-web-alias
Source

add dns domain or dns record after web domain alias

Options: USER ALIAS IP [RESTART]

Examples:


v-add-dns-on-web-alias admin www.example.com 8.8.8.8
This function adds dns domain or dns record based on web domain alias.

v-add-dns-record
Source

add dns record

Options: USER DOMAIN RECORD TYPE VALUE [PRIORITY] [ID] [RESTART] [TTL]

Examples:


v-add-dns-record admin acme.com www A 162.227.73.112
This function is used to add a new DNS record. Complex records of TXT, MX and SRV types can be used by a filling in the 'value' argument. This function also gets an ID parameter for definition of certain record identifiers or for the regulation of records.

v-add-domain
Source

add web/dns/mail domain

Options: USER DOMAIN [IP] [RESTART]

Examples:


v-add-domain admin example.com
This function adds web/dns/mail domain to a server.

v-add-fastcgi-cache
Source

Enable FastCGI cache for nginx

Options: USER DOMAIN [DURATION] [RESTART]

Examples:


v-add-fastcgi-cache user domain.tld 30m
This function enables FastCGI cache for nginx Acceptable values for duration is time in seconds (10s) minutes (10m) or days (10d) Add "yes" as last parameter to restart nginx

v-add-firewall-ban
Source

add firewall blocking rule

Options: IPV4_CIDR CHAIN

Examples:


v-add-firewall-ban 37.120.129.20 MAIL
This function adds new blocking rule to system firewall

v-add-firewall-chain
Source

add firewall chain

Options: CHAIN [PORT] [PROTOCOL]

Examples:


v-add-firewall-chain CRM 5678 TCP
This function adds new rule to system firewall

v-add-firewall-ipset
Source

add firewall ipset

Options: NAME [SOURCE] [IPVERSION] [AUTOUPDATE] [REFRESH]

Examples:


v-add-firewall-ipset country-nl "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/nl/ipv4-aggregated.txt"
This function adds new ipset to system firewall

v-add-firewall-rule
Source

add firewall rule

Options: ACTION IPV4_CIDR PORT [PROTOCOL] [COMMENT] [RULE]

Examples:


v-add-firewall-rule DROP 185.137.111.77 25
This function adds new rule to system firewall

v-add-fs-archive
Source

archive directory

Options: USER ARCHIVE SOURCE [SOURCE...]

Examples:


v-add-fs-archive admin archive.tar readme.txt
This function creates tar archive

v-add-fs-directory
Source

add directory

Options: USER DIRECTORY

Examples:


v-add-fs-directory admin mybar
This function creates new directory on the file system

v-add-fs-file
Source

add file

Options: USER FILE

Examples:


v-add-fs-file admin readme.md
This function creates new files on file system

v-add-letsencrypt-domain
Source

check letsencrypt domain

Options: USER DOMAIN [ALIASES] [MAIL]

Examples:


v-add-letsencrypt-domain admin wonderland.com www.wonderland.com,demo.wonderland.com
example: v-add-letsencrypt-domain admin wonderland.com '' yes
This function check and validates domain with Let's Encrypt

v-add-letsencrypt-host
Source

add letsencrypt for host and backend

Options: –

This function check and validates the backend certificate and generate a new let's encrypt certificate.

v-add-letsencrypt-user
Source

register letsencrypt user account

Options: USER

Examples:


v-add-letsencrypt-user bob
This function creates and register LetsEncrypt account

v-add-mail-account
Source

add mail domain account

Options: USER DOMAIN ACCOUNT PASSWORD [QUOTA]

Examples:


v-add-mail-account user example.com john P4$$vvOrD
This function add new email account.

v-add-mail-account-alias
Source

add mail account alias aka nickname

Options: USER DOMAIN ACCOUNT ALIAS

Examples:


v-add-mail-account-alias admin acme.com alice alicia
This function add new email alias.

v-add-mail-account-autoreply
Source

add mail account autoreply message

Options: USER DOMAIN ACCOUNT MESSAGE

Examples:


v-add-mail-account-autoreply admin example.com user Hello from e-mail!
This function add new email account.

v-add-mail-account-forward
Source

add mail account forward address

Options: USER DOMAIN ACCOUNT FORWARD

Examples:


v-add-mail-account-forward admin acme.com alice bob
This function add new email account.

v-add-mail-account-fwd-only
Source

add mail account forward-only flag

Options: USER DOMAIN ACCOUNT

Examples:


v-add-mail-account-fwd-only admin example.com user
This function adds fwd-only flag

v-add-mail-domain
Source

add mail domain

Options: USER DOMAIN [ANTISPAM] [ANTIVIRUS] [DKIM] [DKIM_SIZE] [RESTART] [REJECT_SPAM]

Examples:


v-add-mail-domain admin mydomain.tld
This function adds MAIL domain.

v-add-mail-domain-antispam
Source

add mail domain antispam support

Options: USER DOMAIN

Examples:


v-add-mail-domain-antispam admin mydomain.tld
This function enables spamassasin for incoming emails.

v-add-mail-domain-antivirus
Source

add mail domain antivirus support

Options: USER DOMAIN

Examples:


v-add-mail-domain-antivirus admin mydomain.tld
This function enables clamav scan for incoming emails.

v-add-mail-domain-catchall
Source

add mail domain catchall account

Options: USER DOMAIN EMAIL

Examples:


v-add-mail-domain-catchall admin example.com master@example.com
This function enables catchall account for incoming emails.

v-add-mail-domain-dkim
Source

add mail domain dkim support

Options: USER DOMAIN [DKIM_SIZE]

Examples:


v-add-mail-domain-dkim admin acme.com
This function adds DKIM signature to outgoing domain emails.

v-add-mail-domain-reject
Source

add mail domain reject spam support

Options: USER DOMAIN

Examples:


v-add-mail-domain-reject admin mydomain.tld
The function enables spam rejection for incoming emails.

v-add-mail-domain-smtp-relay
Source

Add mail domain smtp relay support

Options: USER DOMAIN HOST [USERNAME] [PASSWORD] [PORT]

Examples:


v-add-mail-domain-smtp-relay user domain.tld srv.smtprelay.tld uname123 pass12345
This function adds mail domain smtp relay support.

v-add-mail-domain-ssl
Source

add mail SSL for $domain

Options: USER DOMAIN SSL_DIR [RESTART]

This function turns on SSL support for a mail domain. Parameter ssl_dir is a path to a directory where 2 or 3 ssl files can be found. Certificate file mail.domain.tld.crt and its key mail.domain.tld.key are mandatory. Certificate authority mail.domain.tld.ca file is optional.

v-add-mail-domain-webmail
Source

add webmail support for a domain

Options: USER DOMAIN [WEBMAIL] [RESTART] [QUIET]

Examples:


v-add-mail-domain-webmail user domain.com
example: v-add-mail-domain-webmail user domain.com snappymail
example: v-add-mail-domain-webmail user domain.com roundcube
This function enables webmail client for a mail domain.

v-add-remote-dns-domain
Source

add remote dns domain

Options: USER DOMAIN [FLUSH]

Examples:


v-add-remote-dns-domain admin mydomain.tld yes
This function synchronise dns domain with the remote server.

v-add-remote-dns-host
Source

add new remote dns host

Options: HOST PORT USER PASSWORD [TYPE] [DNS_USER]

Examples:


v-add-remote-dns-host slave.your_host.com 8083 admin your_passw0rd
v-add-remote-dns-host slave.your_host.com 8083 api_key ''
This function adds remote dns server to the dns cluster. As alternative api_key generated on the slave server. See v-generate-api-key can be used to connect the remote dns server

v-add-remote-dns-record
Source

add remote dns domain record

Options: USER DOMAIN ID

Examples:


v-add-remote-dns-record bob acme.com 23
This function synchronise dns domain with the remote server.

v-add-sys-api-ip
Source

add IP address to API allow list

Options: IP

Examples:


v-add-sys-api-ip 1.1.1.1
v-add-sys-cgroups
Source

Enable cgroup support for user

Options: –

Examples:


v-add-sys-cgroup
v-add-sys-dependencies
Source

Options:

Add php dependencies to Hestia options: [MODE]

v-add-sys-filemanager
Source

add file manager functionality to Hestia Control Panel

Options: [MODE]

This function installs the File Manager on the server for access through the Web interface.

v-add-sys-firewall
Source

add system firewall

Options: –

This function enables the system firewall.

v-add-sys-ip
Source

add system IP address

Options: IP NETMASK [INTERFACE] [USER] [IP_STATUS] [IP_NAME] [NAT_IP]

Examples:


v-add-sys-ip 203.0.113.1 255.255.255.0
This function adds IP address into a system. It also creates rc scripts. You can specify IP name which will be used as root domain for temporary aliases. For example, if you set a1.myhosting.com as name, each new domain created on this IP will automatically receive alias $domain.a1.myhosting.com. Of course you must have wildcard record *.a1.myhosting.com pointed to IP. This feature is very handy when customer wants to test domain before dns migration.

v-add-sys-pma-sso
Source

enables support for single sign on phpMyAdmin

Options: [MODE]

This function enables support for SSO to phpMyAdmin

v-add-sys-quota
Source

add system quota

Options: –

This function enables filesystem quota on /home partition Some kernels do require additional packages to be installed first

v-add-sys-roundcube
Source

Install Roundcube webmail client

Options: [MODE]

This function installs the Roundcube webmail client.

v-add-sys-sftp-jail
Source

add system sftp jail

Options: [RESTART]

Examples:


v-add-sys-sftp-jail yes
This function enables sftp jailed environment.

v-add-sys-smtp
Source

Add SMTP Account for logging, notification and internal mail

Options: DOMAIN PORT SMTP_SECURITY USERNAME PASSWORD EMAIL

Examples:


v-add-sys-smtp example.com 587 STARTTLS test@domain.com securepassword test@example.com
This function allows configuring a SMTP account for the server to use for logging, notification and warn emails etc.

v-add-sys-smtp-relay
Source

add system wide smtp relay support

Options: HOST [USERNAME] [PASSWORD] [PORT]

Examples:


v-add-sys-smtp-relay srv.smtprelay.tld uname123 pass12345
This function adds system wide smtp relay support.

v-add-sys-snappymail
Source

Install SnappyMail webmail client

Options: [MODE]

This function installs the SnappyMail webmail client.

v-add-sys-ssh-jail
Source

add system ssh jail

Options: –

This function enables ssh jailed environment.

v-add-sys-web-terminal
Source

add system web terminal

Options: –

This function enables the web terminal.

v-add-user
Source

add system user

Options: USER PASSWORD EMAIL [PACKAGE] [NAME] [LASTNAME]

Examples:


v-add-user user 'P4$$w@rD' bgates@aol.com
This function creates new user account.

v-add-user-2fa
Source

add 2fa to existing user

Options: USER

Examples:


v-add-user-2fa admin
This function creates a new 2fa token for user.

v-add-user-composer
Source

add composer (php dependency manager) for a user

Options: USER

Examples:


v-add-user-composer user [version]
This function adds support for composer (php dependency manager) Homepage: https://getcomposer.org/

v-add-user-notification
Source

add user notification

Options: USER TOPIC NOTICE [TYPE]

This function adds a new user notification to the panel.

v-add-user-package
Source

adding user package

Options: TMPFILE PACKAGE [REWRITE]

This function adds new user package to the system.

v-add-user-sftp-jail
Source

add user sftp jail

Options: USER [RESTART]

Examples:


v-add-user-sftp-jail admin
This function enables sftp jailed environment

v-add-user-sftp-key
Source

add user sftp key

Options: USER [TTL]

This function creates and updates SSH keys for used with the File Manager.

v-add-user-ssh-key
Source

add ssh key

Options: USER KEY

Examples:


v-add-user-ssh-key user 'valid ssh key'
Function check if $user/.ssh/authorized_keys exists and create it. After that it append the new key(s)

v-add-user-wp-cli
Source

add wp-cli for a user

Options: USER

Examples:


v-add-user-wp-cli user
This function adds support for wp-cli to the user account

v-add-web-domain
Source

add web domain

Options: USER DOMAIN [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS]

Examples:


v-add-web-domain admin wonderland.com 192.18.22.43 yes www.wonderland.com
This function adds virtual host to a server. In cases when ip is undefined in the script, "default" template will be used. The alias of www.domain.tld type will be automatically assigned to the domain unless "none" is transmited as argument. If ip have associated dns name, this domain will also get the alias domain-tpl.$ipname. An alias with the ip name is useful during the site testing while dns isn't moved to server yet.

v-add-web-domain-alias
Source

add web domain alias

Options: USER DOMAIN ALIASES [RESTART]

Examples:


v-add-web-domain-alias admin acme.com www.acme.com yes
This function adds one or more aliases to a domain (it is also called "domain parking"). This function supports wildcards <*.domain.tld>.

v-add-web-domain-allow-users
Source

Allow other users create subdomains

Options: USER DOMAIN

Examples:


v-add-web-domain-allow-users admin admin.com
Bypass the rule check for Enforce subdomain ownership for a specific domain. Enforce subdomain ownership setting in /edit/server/ set to no will always overwrite this behaviour eg: admin adds admin.com user can create user.admin.com

v-add-web-domain-backend
Source

add web domain backend

Options: USER DOMAIN [TEMPLATE] [RESTART]

Examples:


v-add-web-domain-backend admin example.com default yes
This function is used to add the web backend configuration.

v-add-web-domain-ftp
Source

add ftp account for web domain.

Options: USER DOMAIN FTP_USER FTP_PASSWORD [FTP_PATH]

Examples:


v-add-web-domain-ftp alice wonderland.com alice_ftp p4$$vvOrD
This function creates additional ftp account for web domain.

v-add-web-domain-httpauth
Source

add password protection for web domain

Options: USER DOMAIN AUTH_USER AUTH_PASSWORD [RESTART]

Examples:


v-add-web-domain-httpauth admin acme.com user02 super_pass
This function is used for securing web domain with http auth

v-add-web-domain-proxy
Source

add webdomain proxy support

Options: USER DOMAIN [TEMPLATE] [EXTENTIONS] [RESTART]

Examples:


v-add-web-domain-proxy admin example.com
This function enables proxy support for a domain. This can significantly improve website speed.

v-add-web-domain-redirect
Source

Adding force redirect to domain

Options: USER DOMAIN REDIRECT HTTPCODE [RESTART]

Examples:


v-add-web-domain-redirect user domain.tld domain.tld
example: v-add-web-domain-redirect user domain.tld www.domain.tld
example: v-add-web-domain-redirect user domain.tld shop.domain.tld
example: v-add-web-domain-redirect user domain.tld different-domain.com
example: v-add-web-domain-redirect user domain.tld shop.different-domain.com
example: v-add-web-domain-redirect user domain.tld different-domain.com 302
Function creates a forced redirect to a domain

v-add-web-domain-ssl
Source

adding ssl for domain

Options: USER DOMAIN SSL_DIR [SSL_HOME] [RESTART]

Examples:


v-add-web-domain-ssl admin example.com /tmp/folder/contains/certificate/files/
This function turns on SSL support for a domain. Parameter ssl_dir is a path to directory where 2 or 3 ssl files can be found. Certificate file domain.tld.crt and its key domain.tld.key are mandatory. Certificate authority domain.tld.ca file is optional. If home directory parameter (ssl_home) is not set, https domain uses public_shtml as separate documentroot directory.

v-add-web-domain-ssl-force
Source

Adding force SSL for a domain

Options: USER DOMAIN [RESTART] [QUIET]

Examples:


v-add-web-domain-ssl-force admin acme.com
This function forces SSL for the requested domain.

v-add-web-domain-ssl-hsts
Source

Adding hsts to a domain

Options: USER DOMAIN [RESTART] [QUIET]

This function enables HSTS for the requested domain.

v-add-web-domain-ssl-preset
Source

Adding force SSL for a domain

Options: USER DOMAIN [SSL]

Up on creating an web domain set the SSL Force values due to the delay of LE due to DNS propergation over DNS cluster When LE has been activated it will set the actions

v-add-web-domain-stats
Source

add log analyser to generate domain statistics

Options: USER DOMAIN TYPE

Examples:


v-add-web-domain-stats admin example.com awstats
This function is used for enabling log analyser system to a domain. For viewing the domain statistics use http://domain.tld/vstats/ link. Access this page is not protected by default. If you want to secure it with passwords you should use v-add-web-domain_stat_auth script.

v-add-web-domain-stats-user
Source

add password protection to web domain statistics

Options: USER DOMAIN STATS_USER STATS_PASSWORD [RESTART]

Examples:


v-add-web-domain-stats-user admin example.com watchdog your_password
This function is used for securing the web statistics page.

v-add-web-php
Source

add php fpm version

Options: VERSION

Examples:


v-add-web-php 8.0
Install php-fpm for provided version.

v-backup-user
Source

backup system user with all its objects

Options: USER NOTIFY

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-backup-user-config
Source

backup system user config only

Options: USER NOTIFY

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-backup-user-restic
Source

backup system user with all its objects to restic backup

Options: USER NOTIFY

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-backup-users
Source

backup all users

Options: –

This function backups all system users.

v-backup-users-restic
Source

backup all users

Options: –

Examples:


v-backup-users
This function backups all system users.

v-change-cron-job
Source

change cron job

Options: USER JOB MIN HOUR DAY MONTH WDAY CRON_COMMAND

Examples:


v-change-cron-job admin 7 * * * * * /usr/bin/uptime
This function is used for changing existing job. It fully replace job parameters with new one but with same id.

v-change-database-host-password
Source

change database server password

Options: TYPE HOST USER PASSWORD

Examples:


v-change-database-host-password mysql localhost wp_user pA$$w@rD
This function changes database server password.

v-change-database-owner
Source

change database owner

Options: DATABASE USER

Examples:


v-change-database-owner mydb alice
This function for changing database owner.

v-change-database-password
Source

change database password

Options: USER DATABASE DBPASS

Examples:


v-change-database-password admin wp_db neW_pAssWorD
This function for changing database user password to a database. It uses the full name of database as argument.

v-change-database-user
Source

change database username

Options: USER DATABASE DBUSER [DBPASS]

Examples:


v-change-database-user admin my_db joe_user
This function for changing database user. It uses the

v-change-dns-domain-dnssec
Source

change dns domain dnssec status

Options: USER DOMAIN STATUS

Examples:


v-change-dns-domain-dnssec admin domain.pp.ua yes
v-change-dns-domain-exp
Source

change dns domain expiration date

Options: USER DOMAIN EXP

Examples:


v-change-dns-domain-exp admin domain.pp.ua 2020-11-20
This function of changing the term of expiration domain's registration. The serial number will be refreshed automatically during update.

v-change-dns-domain-ip
Source

change dns domain ip address

Options: USER DOMAIN IP [RESTART]

Examples:


v-change-dns-domain-ip admin domain.com 123.212.111.222
This function for changing the main ip of DNS zone.

v-change-dns-domain-soa
Source

change dns domain soa record

Options: USER DOMAIN SOA [RESTART]

Examples:


v-change-dns-domain-soa admin acme.com d.ns.domain.tld
This function for changing SOA record. This type of records can not be modified by v-change-dns-record call.

v-change-dns-domain-tpl
Source

change dns domain template

Options: USER DOMAIN TEMPLATE [RESTART]

Examples:


v-change-dns-domain-tpl admin example.com child-ns yes
This function for changing the template of records. By updating old records will be removed and new records will be generated in accordance with parameters of new template.

v-change-dns-domain-ttl
Source

change dns domain ttl

Options: USER DOMAIN TTL [RESTART]

Examples:


v-change-dns-domain-ttl alice example.com 14400
This function for changing the time to live TTL parameter for all records.

v-change-dns-record
Source

change dns domain record

Options: USER DOMAIN ID RECORD TYPE VALUE [PRIORITY] [RESTART] [TTL]

Examples:


v-change-dns-record admin domain.ua 42 192.18.22.43
This function for changing DNS record.

v-change-dns-record-id
Source

change dns domain record id

Options: USER DOMAIN ID NEWID [RESTART]

Examples:


v-change-dns-record-id admin acme.com 24 42 yes
This function for changing internal record id.

v-change-domain-owner
Source

change domain owner

Options: DOMAIN USER

Examples:


v-change-domain-owner www.example.com bob
This function of changing domain ownership.

v-change-firewall-rule
Source

change firewall rule

Options: RULE ACTION IPV4_CIDR PORT [PROTOCOL] [COMMENT]

Examples:


v-change-firewall-rule 3 ACCEPT 5.188.123.17 443
This function is used for changing existing firewall rule. It fully replace rule with new one but keeps same id.

v-change-fs-file-permission
Source

change file permission

Options: USER FILE PERMISSIONS

Examples:


v-change-fs-file-permission admin readme.txt 0777
This function changes file access permissions on the file system

v-change-mail-account-password
Source

change mail account password

Options: USER DOMAIN ACCOUNT PASSWORD

Examples:


v-change-mail-account-password admin mydomain.tld user p4$$vvOrD
This function changes email account password.

v-change-mail-account-quota
Source

change mail account quota

Options: USER DOMAIN ACCOUNT QUOTA

Examples:


v-change-mail-account-quota admin mydomain.tld user01 unlimited
This function changes email account disk quota.

v-change-mail-account-rate-limit
Source

change mail account rate limit

Options: USER DOMAIN ACCOUNT RATE

Examples:


v-change-mail-account-rate-limit admin mydomain.tld user01 100
This function changes email account rate limit. Use system to use domain or "server" setting

v-change-mail-domain-catchall
Source

change mail domain catchall email

Options: USER DOMAIN EMAIL

Examples:


v-change-mail-domain-catchall user01 mydomain.tld master@mydomain.tld
This function changes mail domain catchall.

v-change-mail-domain-rate-limit
Source

change mail domain rate limit

Options: USER DOMAIN RATE

Examples:


v-change-mail-domain-rate-limit admin mydomain.tld 100
This function changes email account rate limit for the domain. Account specific setting will overwrite domain setting!

v-change-mail-domain-sslcert
Source

change domain ssl certificate

Options: USER DOMAIN SSL_DIR [RESTART]

This function changes SSL domain certificate and the key. If ca file present it will be replaced as well.

v-change-remote-dns-domain-exp
Source

change remote dns domain expiration date

Options: USER DOMAIN

This function synchronise dns domain with the remote server.

v-change-remote-dns-domain-soa
Source

change remote dns domain SOA

Options: USER DOMAIN

Examples:


v-change-remote-dns-domain-soa admin example.org.uk
This function synchronise dns domain with the remote server.

v-change-remote-dns-domain-ttl
Source

change remote dns domain TTL

Options: USER DOMAIN

Examples:


v-change-remote-dns-domain-ttl admin domain.tld
This function synchronise dns domain with the remote server.

v-change-sys-api
Source

Enable / Disable API access

Options: STATUS

Examples:


v-change-sys-api enable legacy
# Enable legacy api currently default on most of api based systems
example: v-change-sys-api enable api
# Enable api
v-change-sys-api disable
# Disable API
Enabled / Disable API

v-change-sys-config-value
Source

change sysconfig value

Options: KEY VALUE

Examples:


v-change-sys-config-value VERSION 1.0
This function is for changing main config settings such as COMPANY_NAME or COMPANY_EMAIL and so on.

v-change-sys-db-alias
Source

change phpmyadmin/phppgadmin alias url

Options: TYPE ALIAS

Examples:


v-change-sys-db-alias pma phpmyadmin
# Sets phpMyAdmin alias to phpmyadmin
v-change-sys-db-alias pga phppgadmin
# Sets phpPgAdmin alias to phppgadmin
This function changes the database editor url in apache2 or nginx configuration.

v-change-sys-demo-mode
Source

enable or disable demo mode

Options: ACTIVE

This function will set the demo mode variable, which will prevent usage of certain v-scripts in the backend and prevent modification of objects in the control panel. It will also disable virtual hosts for Apache and NGINX for domains which have been created.

v-change-sys-hestia-ssl
Source

change hestia ssl certificate

Options: SSL_DIR [RESTART]

Examples:


v-change-sys-hestia-ssl /home/new/dir/path yes
This function changes hestia SSL certificate and the key.

v-change-sys-hostname
Source

change hostname

Options: HOSTNAME

Examples:


v-change-sys-hostname mydomain.tld
This function for changing system hostname.

v-change-sys-ip-name
Source

change IP name

Options: IP NAME

Examples:


v-change-sys-ip-name 203.0.113.1 acme.com
This function for changing dns domain associated with IP.

v-change-sys-ip-nat
Source

change NAT IP address

Options: IP NAT_IP [RESTART]

Examples:


v-change-sys-ip-nat 10.0.0.1 203.0.113.1
This function for changing NAT IP associated with IP.

v-change-sys-ip-owner
Source

change IP owner

Options: IP USER

Examples:


v-change-sys-ip-owner 203.0.113.1 admin
This function of changing IP address ownership.

v-change-sys-ip-status
Source

change IP status

Options: IP IP_STATUS

Examples:


v-change-sys-ip-status 203.0.113.1 yourstatus
This function of changing an IP address's status.

v-change-sys-language
Source

change sys language

Options: LANGUAGE [UPDATE_USERS]

Examples:


v-change-sys-language ru
This function for changing system language.

v-change-sys-php
Source

Change default php version server wide

Options: VERSION

Examples:


v-change-sys-php 8.0
v-change-sys-port
Source

change system backend port

Options: PORT

Examples:


v-change-sys-port 5678
This function for changing the system backend port in NGINX configuration.

v-change-sys-release
Source

update web templates

Options: [RESTART]

This function for changing the release branch for the Hestia Control Panel. This allows the user to switch between stable and pre-release builds which will automaticlly update based on the appropriate release schedule if auto-update is turned on.

v-change-sys-service-config
Source

change service config

Options: CONFIG SERVICE [RESTART]

Examples:


v-change-sys-service-config /home/admin/dovecot.conf dovecot yes
This function for changing service confguration.

v-change-sys-timezone
Source

change system timezone

Options: TIMEZONE

Examples:


v-change-sys-timezone Europe/Berlin
This function for changing system timezone.

v-change-sys-web-terminal-port
Source

change system web terminal backend port

Options: PORT

Examples:


v-change-sys-web-terminal-port 5678
This function for changing the system's web terminal backend port in NGINX configuration.

v-change-sys-webmail
Source

change webmail alias url

Options: WEBMAIL

Examples:


v-change-sys-webmail YourtrickyURLhere
This function changes the webmail url in apache2 or nginx configuration.

v-change-user-config-value
Source

changes user configuration value

Options: USER KEY VALUE

Examples:


v-change-user-config-value admin ROLE admin
Changes key/value for specified user.

v-change-user-contact
Source

change user contact email

Options: USER EMAIL

Examples:


v-change-user-contact admin admin@yahoo.com
This function for changing of e-mail associated with a certain user.

v-change-user-language
Source

change user language

Options: USER LANGUAGE

Examples:


v-change-user-language admin en
This function for changing language.

v-change-user-name
Source

change user full name

Options: USER NAME [LAST_NAME]

Examples:


v-change-user-name admin John Smith
This function allow to change user's full name.

v-change-user-ns
Source

change user name servers

Options: USER NS1 NS2 [NS3] [NS4] [NS5] [NS6] [NS7] [NS8]

Examples:


v-change-user-ns ns1.domain.tld ns2.domain.tld
This function for changing default name servers for specific user.

v-change-user-package
Source

change user package

Options: USER PACKAGE [FORCE]

Examples:


v-change-user-package admin yourpackage
This function changes user's hosting package.

v-change-user-password
Source

change user password

Options: USER PASSWORD

Examples:


v-change-user-password admin NewPassword123
This function changes user's password and updates RKEY value.

v-change-user-php-cli
Source

add php version alias to .bash_aliases

Options: USER VERSION

Examples:


v-change-user-php-cli user 7.4
add line to .bash_aliases to set default php command line version when multi-php is enabled.

v-change-user-rkey
Source

change user random key

Options: USER [HASH]

This function changes user's RKEY value thats has been used for security value to be used forgot password function only.

v-change-user-role
Source

updates user role

Options: USER ROLE

Examples:


v-change-user-role user administrator
Give/revoke user administrator rights to manage all accounts as admin

v-change-user-shell
Source

change user shell

Options: USER SHELL

Examples:


v-change-user-shell admin nologin
This function changes system shell of a user. Shell gives ability to use ssh.

v-change-user-sort-order
Source

updates user role

Options: USER SORT_ORDER

Examples:


v-change-user-sort-order user date
Changes web UI display sort order for specified user.

v-change-user-template
Source

change user default template

Options: USER TYPE TEMPLATE

Examples:


v-change-user-template admin WEB wordpress
This function changes default user web template.

v-change-user-theme
Source

updates user theme

Options: USER THEME

Examples:


v-change-user-theme admin dark
example: v-change-user-theme peter vestia
Changes web UI display theme for specified user.

v-change-web-domain-backend-tpl
Source

change web domain backend template

Options: USER DOMAIN TEMPLATE [RESTART]

Examples:


v-change-web-domain-backend-tpl admin acme.com PHP-7_4
This function changes backend template

v-change-web-domain-dirlist
Source

enable/disable directory listing

Options: USER DOMAIN MODE

Examples:


v-change-web-domain-dirlist user demo.com on
This function is used for changing the directory list mode.

v-change-web-domain-docroot
Source

Changes the document root for an existing web domain

Options: USER DOMAIN TARGET_DOMAIN [DIRECTORY] [PHP]

Examples:


v-change-web-domain-docroot admin domain.tld otherdomain.tld
# add custom docroot
# points domain.tld to otherdomain.tld's document root.
v-change-web-domain-docroot admin test.local default
# remove custom docroot
# returns document root to default value for domain.
This call changes the document root of a chosen web domain to another available domain under the user context.

v-change-web-domain-ftp-password
Source

change ftp user password.

Options: USER DOMAIN FTP_USER FTP_PASSWORD

Examples:


v-change-web-domain-ftp-password admin example.com ftp_usr ftp_qwerty
This function changes ftp user password.

v-change-web-domain-ftp-path
Source

change path for ftp user.

Options: USER DOMAIN FTP_USER FTP_PATH

Examples:


v-change-web-domain-ftp-path admin example.com /home/admin/example.com
This function changes ftp user path.

v-change-web-domain-httpauth
Source

change password for http auth user

Options: USER DOMAIN AUTH_USER AUTH_PASSWORD [RESTART]

Examples:


v-change-web-domain-httpauth admin acme.com alice white_rA$$bIt
This function is used for changing http auth user password

v-change-web-domain-ip
Source

change web domain ip

Options: USER DOMAIN DOMAIN [RESTART]

Examples:


v-change-web-domain-ip admin example.com 167.86.105.230 yes
This function is used for changing domain ip

v-change-web-domain-name
Source

change web domain name

Options: USER DOMAIN NEW_DOMAIN [RESTART]

Examples:


v-change-web-domain-name alice wonderland.com lookinglass.com yes
This function is used for changing the domain name.

v-change-web-domain-proxy-tpl
Source

change web domain proxy template

Options: USER DOMAIN TEMPLATE [EXTENTIONS] [RESTART]

Examples:


v-change-web-domain-proxy-tpl admin domain.tld hosting
This function changes proxy template

v-change-web-domain-sslcert
Source

change domain ssl certificate

Options: USER DOMAIN SSL_DIR [RESTART]

Examples:


v-change-web-domain-sslcert admin example.com /home/admin/tmp
This function changes SSL domain certificate and the key. If ca file present it will be replaced as well.

v-change-web-domain-sslhome
Source

changing domain ssl home

Options: USER DOMAIN SSL_HOME [RESTART]

Examples:


v-change-web-domain-sslhome admin acme.com single
example: v-change-web-domain-sslhome admin acme.com same
This function changes SSL home directory. Single will separate the both public_html / public_shtml. Same will always point to public_shtml

v-change-web-domain-stats
Source

change web domain statistics

Options: USER DOMAIN TYPE

Examples:


v-change-web-domain-stats admin example.com awstats
This function of deleting site's system of statistics. Its type is automatically chooses from client's configuration file.

v-change-web-domain-tpl
Source

change web domain template

Options: USER DOMAIN TEMPLATE [RESTART]

Examples:


v-change-web-domain-tpl admin acme.com opencart
This function changes template of the web configuration file. The content of webdomain directories remains untouched.

v-check-access-key
Source

check access key

Options: ACCESS_KEY_ID SECRET_ACCESS_KEY COMMAND [IP] [FORMAT]

Examples:


v-check-access-key key_id secret v-purge-nginx-cache 127.0.0.1 json
Checks if the key exists;
Checks if the secret belongs to the key;
Checks if the key user is suspended;
Checks if the key has permission to run the command.
v-check-api-key
Source

check api key

Options: KEY [IP]

Examples:


v-check-api-key random_key 127.0.0.1
This function checks a key file in $HESTIA/data/keys/

v-check-fs-permission
Source

open file

Options: USER FILE

Examples:


v-check-fs-permission admin readme.txt
This function opens/reads files on the file system

v-check-mail-account-hash
Source

check user password

Options: TYPE PASSWORD HASH

Examples:


v-check-mail-account-hash ARGONID2 PASS HASH
This function verifies email account password hash

v-check-user-2fa
Source

check user token

Options: USER TOKEN

Examples:


v-check-user-2fa admin 493690
This function verifies user 2fa token.

v-check-user-hash
Source

check user hash

Options: USER HASH [IP]

Examples:


v-check-user-hash admin CN5JY6SMEyNGnyCuvmK5z4r7gtHAC4mRZ...
This function verifies user hash

v-check-user-password
Source

check user password

Options: USER PASSWORD [IP] [RETURN_HASH]

Examples:


v-check-user-password admin qwerty1234
This function verifies user password from file

v-copy-fs-directory
Source

copy directory

Options: USER SRC_DIRECTORY DST_DIRECTORY

Examples:


v-copy-fs-directory alice /home/alice/dir1 /home/bob/dir2
This function copies directory on the file system

v-copy-fs-file
Source

copy file

Options: USER SRC_FILE DST_FILE

Examples:


v-copy-fs-file admin readme.txt readme_new.txt
This function copies file on the file system

v-copy-user-package
Source

duplicate existing package

Options: PACKAGE NEW_PACKAGE

Examples:


v-copy-user-package default new
This function allows the user to duplicate an existing package file to facilitate easier configuration.

v-delete-access-key
Source

delete access key

Options: ACCESS_KEY_ID

Examples:


v-delete-access-key mykey
This function removes a key from in $HESTIA/data/access-keys/

v-delete-backup-host
Source

delete backup ftp server

Options: TYPE [HOST]

Examples:


v-delete-backup-host sftp
This function deletes ftp backup host

v-delete-backup-host-restic
Source

delete backup ftp server

Options: –

Examples:


v-delete-backup-host sftp
This function deletes ftp backup host

v-delete-cron-hestia-autoupdate
Source

delete hestia autoupdate cron job

Options: –

This function deletes hestia autoupdate cron job.

v-delete-cron-job
Source

delete cron job

Options: USER JOB

Examples:


v-delete-cron-job admin 9
This function deletes cron job.

v-delete-cron-reports
Source

delete cron reports

Options: USER

Examples:


v-delete-cron-reports admin
This function for disabling reports on cron tasks and administrative notifications.

v-delete-cron-restart-job
Source

delete restart job

Options: –

This function for disabling restart cron tasks

v-delete-database
Source

delete database

Options: USER DATABASE

Examples:


v-delete-database admin wp_db
This function for deleting the database. If database user have access to another database, he will not be deleted.

v-delete-database-host
Source

delete database server

Options: TYPE HOST

Examples:


v-delete-database-host pgsql localhost
This function for deleting the database host from hestia configuration. It will be deleted if there are no databases created on it only.

v-delete-database-temp-user
Source

deletes temp database user

Options: USER DBUSER [TYPE] [HOST]

Examples:


v-delete-database-temp-user wordpress hestia_sso_user mysql
Revokes "temp user" access to a database and removes the user To be used in combination with v-add-database-temp-user

v-delete-databases
Source

delete user databases

Options: USER

Examples:


v-delete-databases admin
This function deletes all user databases.

v-delete-dns-domain
Source

delete dns domain

Options: USER DOMAIN

Examples:


v-delete-dns-domain alice acme.com
This function for deleting DNS domain. By deleting it all records will also be deleted.

v-delete-dns-domains
Source

delete dns domains

Options: USER [RESTART]

Examples:


v-delete-dns-domains bob
This function for deleting all users DNS domains.

v-delete-dns-domains-src
Source

delete dns domains based on SRC field

Options: USER SRC [RESTART]

Examples:


v-delete-dns-domains-src admin '' yes
This function for deleting DNS domains related to a certain host.

v-delete-dns-on-web-alias
Source

delete dns domain or dns record based on web domain alias

Options: USER DOMAIN ALIAS [RESTART]

Examples:


v-delete-dns-on-web-alias admin example.com www.example.com
This function deletes dns domain or dns record based on web domain alias.

v-delete-dns-record
Source

delete dns record

Options: USER DOMAIN ID [RESTART]

Examples:


v-delete-dns-record bob acme.com 42 yes
This function for deleting a certain record of DNS zone.

v-delete-domain
Source

delete web/dns/mail domain

Options: USER DOMAIN

Examples:


v-delete-domain admin domain.tld
This function deletes web/dns/mail domain.

v-delete-fastcgi-cache
Source

Disable FastCGI cache for nginx

Options: USER DOMAIN [RESTART]

Examples:


v-delete-fastcgi-cache user domain.tld
This function disables FastCGI cache for nginx

v-delete-firewall-ban
Source

delete firewall blocking rule

Options: IPV4_CIDR CHAIN

Examples:


v-delete-firewall-ban 198.11.130.250 MAIL
This function deletes blocking rule from system firewall

v-delete-firewall-chain
Source

delete firewall chain

Options: CHAIN

Examples:


v-delete-firewall-chain WEB
This function adds new rule to system firewall

v-delete-firewall-ipset
Source

delete firewall ipset

Options: NAME

Examples:


v-delete-firewall-ipset country-nl
This function removes ipset from system and from hestia

v-delete-firewall-rule
Source

delete firewall rule

Options: RULE

Examples:


v-delete-firewall-rule SSH_BLOCK
This function deletes firewall rule.

v-delete-fs-directory
Source

delete directory

Options: USER DIRECTORY

Examples:


v-delete-fs-directory admin report1
This function deletes directory on the file system

v-delete-fs-file
Source

delete file

Options: USER FILE

Examples:


v-delete-fs-file admin readme.txt
This function deletes file on the file system

v-delete-letsencrypt-domain
Source

deleting letsencrypt ssl cetificate for domain

Options: USER DOMAIN [RESTART] [MAIL]

Examples:


v-delete-letsencrypt-domain admin acme.com yes
This function turns off letsencrypt SSL support for a domain.

v-delete-mail-account
Source

delete mail account

Options: USER DOMAIN ACCOUNT

Examples:


v-delete-mail-account admin acme.com alice
This function deletes email account.

v-delete-mail-account-alias
Source

delete mail account alias aka nickname

Options: USER DOMAIN ACCOUNT ALIAS

Examples:


v-delete-mail-account-alias admin example.com alice alicia
This function deletes email account alias.

v-delete-mail-account-autoreply
Source

delete mail account autoreply message

Options: USER DOMAIN ACCOUNT ALIAS

Examples:


v-delete-mail-account-autoreply admin mydomain.tld bob
This function deletes an email accounts autoreply.

v-delete-mail-account-forward
Source

delete mail account forward

Options: USER DOMAIN ACCOUNT EMAIL

Examples:


v-delete-mail-account-forward admin acme.com tony bob@acme.com
This function deletes an email accounts forwarding address.

v-delete-mail-account-fwd-only
Source

delete mail account forward-only flag

Options: USER DOMAIN ACCOUNT

Examples:


v-delete-mail-account-fwd-only admin example.com jack
This function deletes fwd-only flag

v-delete-mail-domain
Source

delete mail domain

Options: USER DOMAIN

Examples:


v-delete-mail-domain admin mydomain.tld
This function for deleting MAIL domain. By deleting it all accounts will also be deleted.

v-delete-mail-domain-antispam
Source

delete mail domain antispam support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-antispam admin mydomain.tld
This function disable spamassasin for incoming emails.

v-delete-mail-domain-antivirus
Source

delete mail domain antivirus support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-antivirus admin mydomain.tld
This function disables clamav scan for incoming emails.

v-delete-mail-domain-catchall
Source

delete mail domain catchall email

Options: USER DOMAIN

Examples:


v-delete-mail-domain-catchall admin mydomain.tld
This function disables mail domain cathcall.

v-delete-mail-domain-dkim
Source

delete mail domain dkim support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-dkim admin mydomain.tld
This function delete DKIM domain pem.

v-delete-mail-domain-reject
Source

delete mail domain reject spam support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-reject admin mydomain.tld
The function disables spam rejection for incoming emails.

v-delete-mail-domain-smtp-relay
Source

Remove mail domain smtp relay support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-smtp-relay user domain.tld
This function removes mail domain smtp relay support.

v-delete-mail-domain-ssl
Source

delete mail domain ssl support

Options: USER DOMAIN

Examples:


v-delete-mail-domain-ssl user demo.com
This function delete ssl certificates.

v-delete-mail-domain-webmail
Source

delete webmail support for a domain

Options: USER DOMAIN [RESTART] [QUIET]

Examples:


v-delete-mail-domain-webmail user demo.com
This function removes support for webmail from a specified mail domain.

v-delete-mail-domains
Source

delete mail domains

Options: USER

Examples:


v-delete-mail-domains admin
This function for deleting all users mail domains.

v-delete-remote-dns-domain
Source

delete remote dns domain

Options: USER DOMAIN

Examples:


v-delete-remote-dns-domain admin example.tld
This function synchronise dns with the remote server.

v-delete-remote-dns-domains
Source

delete remote dns domains

Options: [HOST]

This function deletes remote dns domains.

v-delete-remote-dns-host
Source

delete remote dns host

Options: HOST

Examples:


v-delete-remote-dns-host example.org
This function for deleting the remote dns host from hestia configuration.

v-delete-remote-dns-record
Source

delete remote dns domain record

Options: USER DOMAIN ID

Examples:


v-delete-remote-dns-record user07 acme.com 44
This function synchronise dns with the remote server.

v-delete-sys-api-ip
Source

delete ip adresss from allowed ip list api

Options: IP

Examples:


v-delete-sys-api-ip 1.1.1.1
v-delete-sys-cgroups
Source

delete all cgroups

Options: –

This function disables cgroups

v-delete-sys-filemanager
Source

remove file manager functionality from Hestia Control Panel

Options: [MODE]

This function removes the File Manager and its entry points

v-delete-sys-firewall
Source

delete system firewall

Options: –

This function disables firewall support

v-delete-sys-ip
Source

delete system IP

Options: IP

Examples:


v-delete-sys-ip 203.0.113.1
This function for deleting a system IP. It does not allow to delete first IP on interface and do not allow to delete IP which is used by a web domain.

v-delete-sys-mail-queue
Source

delete exim mail queue

Options: –

This function checks for messages stuck in the exim mail queue and prompts the user to clear the queue if desired.

v-delete-sys-pma-sso
Source

disables support for single sign on PHPMYADMIN

Options: [MODE]

Disables support for SSO to phpMyAdmin

v-delete-sys-quota
Source

delete system quota

Options: –

This function disables filesystem quota on /home partition

v-delete-sys-sftp-jail
Source

delete system sftp jail

Options: –

This function disables sftp jailed environment

v-delete-sys-smtp
Source

Remove SMTP Account for logging, notification and internal mail

Options: –

This function allows configuring a SMTP account for the server to use for logging, notification and warn emails etc.

v-delete-sys-smtp-relay
Source

disable system wide smtp relay support

Options:

options:

v-delete-sys-snappymail
Source

Delete SnappyMail webmail client

Options: –

This function removes the SnappyMail webmail client.

v-delete-sys-ssh-jail
Source

delete system ssh jail

Options: –

This function disables ssh jailed environment

v-delete-sys-web-terminal
Source

delete web terminal

Options: –

This function disables the web terminal.

v-delete-user
Source

delete user

Options: USER [RESTART]

Examples:


v-delete-user whistler
This function deletes a certain user and all his resources such as domains, databases, cron jobs, etc.

v-delete-user-2fa
Source

delete 2fa of existing user

Options: USER

Examples:


v-delete-user-2fa admin
This function deletes 2fa token of a user.

v-delete-user-auth-log
Source

Delete auth log file for user

Options:

This function for deleting a users auth log file

v-delete-user-backup
Source

delete user backup

Options: USER BACKUP

Examples:


v-delete-user-backup admin admin.2012-12-21_00-10-00.tar
This function deletes user backup.

v-delete-user-backup-exclusions
Source

delete backup exclusion

Options: USER [SYSTEM]

Examples:


v-delete-user-backup-exclusions admin
This function for deleting backup exclusion

v-delete-user-ips
Source

delete user ips

Options: USER

Examples:


v-delete-user-ips admin
This function deletes all user's ip addresses.

v-delete-user-log
Source

Delete log file for user

Options: USER

Examples:


v-delete-user-log user
This function for deleting a users log file

v-delete-user-notification
Source

delete user notification

Options: USER NOTIFICATION

Examples:


v-delete-user-notification admin 1
This function deletes user notification.

v-delete-user-package
Source

delete user package

Options: PACKAGE

Examples:


v-delete-user-package admin palegreen
This function for deleting user package.

v-delete-user-sftp-jail
Source

delete user sftp jail

Options: USER

Examples:


v-delete-user-sftp-jail whistler
This function disables sftp jailed environment for USER

v-delete-user-ssh-key
Source

add ssh key

Options: USER KEY

Examples:


v-delete-user-ssh-key user unique_id
Delete user ssh key from authorized_keys

v-delete-user-stats
Source

delete user usage statistics

Options: USER DOMAIN

Examples:


v-delete-user-stats user
example: v-delete-user-stats admin overall
This function deletes user statistics data.

v-delete-web-domain
Source

delete web domain

Options: USER DOMAIN [RESTART]

Examples:


v-delete-web-domain admin wonderland.com
The call of function leads to the removal of domain and all its components (statistics, folders contents, ssl certificates, etc.). This operation is not fully supported by "undo" function, so the data recovery is possible only with a help of reserve copy.

v-delete-web-domain-alias
Source

delete web domain alias

Options: USER DOMAIN ALIAS [RESTART]

Examples:


v-delete-web-domain-alias admin example.com www.example.com
This function of deleting the alias domain (parked domain). By this call default www aliase can be removed as well.

v-delete-web-domain-allow-users
Source

disables other users create subdomains

Options: USER DOMAIN

Examples:


v-delete-web-domain-allow-users admin admin.com
Enable the rule check for Enforce subdomain ownership for a specific domain. Enforce subdomain ownership setting in /edit/server/ set to no will always overwrite this behaviour eg: admin adds admin.com user can create user.admin.com

v-delete-web-domain-backend
Source

deleting web domain backend configuration

Options: USER DOMAIN [RESTART]

Examples:


v-delete-web-domain-backend admin acme.com
This function of deleting the virtualhost backend configuration.

v-delete-web-domain-ftp
Source

delete webdomain ftp account

Options: USER DOMAIN FTP_USER

Examples:


v-delete-web-domain-ftp admin wonderland.com bob_ftp
This function deletes additional ftp account.

v-delete-web-domain-httpauth
Source

delete http auth user

Options: USER DOMAIN AUTH_USER [RESTART]

Examples:


v-delete-web-domain-httpauth admin example.com alice
This function is used for deleting http auth user

v-delete-web-domain-proxy
Source

deleting web domain proxy configuration

Options: USER DOMAIN [RESTART]

Examples:


v-delete-web-domain-proxy alice lookinglass.com
This function of deleting the virtualhost proxy configuration.

v-delete-web-domain-redirect
Source

Delete force redirect to domain

Options: USER DOMAIN [RESTART]

Examples:


v-add-web-domain-redirect user domain.tld
Function delete a forced redirect to a domain

v-delete-web-domain-ssl
Source

delete web domain SSL support

Options: USER DOMAIN [RESTART]

Examples:


v-delete-web-domain-ssl admin acme.com
This function disable https support and deletes SSL certificates.

v-delete-web-domain-ssl-force
Source

remove ssl force from domain

Options: USER DOMAIN [RESTART] [QUIET]

Examples:


v-delete-web-domain-ssl-force admin domain.tld
This function removes force SSL configurations.

v-delete-web-domain-ssl-hsts
Source

remove ssl force from domain

Options: USER DOMAIN [RESTART] [QUIET]

Examples:


v-delete-web-domain-ssl-hsts user domain.tld
This function removes force SSL configurations.

v-delete-web-domain-stats
Source

delete web domain statistics

Options: USER DOMAIN

Examples:


v-delete-web-domain-stats user02 h1.example.com
This function of deleting site's system of statistics. Its type is automatically chooses from client's configuration file.

v-delete-web-domain-stats-user
Source

disable web domain stats authentication support

Options: USER DOMAIN [RESTART]

Examples:


v-delete-web-domain-stats-user admin acme.com
This function removes authentication of statistics system. If the script is called without naming a certain user, all users will be removed. After deleting all of them statistics will be accessible for view without an authentication.

v-delete-web-domains
Source

delete web domains

Options: USER [RESTART]

Examples:


v-delete-web-domains admin
This function deletes all user's webdomains.

v-delete-web-php
Source

delete php fpm version

Options: VERSION

Examples:


v-delete-web-php 7.3
This function checks and delete a fpm php version if not used by any domain.

v-download-backup
Source

Download backup

Options: USER BACKUP

Examples:


v-download-backup admin admin.2020-11-05_05-10-21.tar
This function download back-up from remote server

v-dump-database
Source

Dumps database contents in STDIN or file optional file can be compressed

Options: USER DATABASE [FILE] [COMPRESSION]

Examples:


v-dump-database user user_databse > test.sql
example: v-dump-database user user_databse file gzip
example: v-dump-database user user_databse file zstd
Dumps database in STDIN or file (/backup/user.database.type.sql) For compression gzip or zstd is supported by default plain sql is used

v-dump-site
Source

Dumps the files of a site into a zip archive

Options: USER DOMAIN [TYPE]

Examples:


v-dump-site user domain
example: v-dump-site user domain full
Dumps site files in /backup/user.domain.timestamp.zip

v-export-rrd
Source

export rrd charts as json

Options: [CHART] [TIMESPAN]

Examples:


v-export-rrd chart format
v-extract-fs-archive
Source

archive to directory

Options: USER ARCHIVE DIRECTORY [SELECTED_DIR] [STRIP] [TEST]

Examples:


v-extract-fs-archive admin latest.tar.gz /home/admin
This function extracts archive into directory on the file system

v-generate-api-key
Source

generate api key

Options: –

This function creates a key file in $HESTIA/data/keys/

v-generate-password-hash
Source

generate password hash

Options: HASH_METHOD SALT PASSWORD

Examples:


v-generate-password-hash sha-512 rAnDom_string yourPassWord
This function generates password hash

v-generate-ssl-cert
Source

generate self signed certificate and CSR request

Options: DOMAIN EMAIL COUNTRY STATE CITY ORG UNIT [ALIASES] [FORMAT]

Examples:


v-generate-ssl-cert example.com mail@yahoo.com USA California Monterey ACME.COM IT
This function generates self signed SSL certificate and CSR request

v-get-dns-domain-value
Source

get dns domain value

Options: USER DOMAIN KEY

Examples:


v-get-dns-domain-value admin example.com SOA
This function for getting a certain DNS domain parameter.

v-get-fs-file-type
Source

get file type

Options: USER FILE

Examples:


v-get-fs-file-type admin index.html
This function shows file type

v-get-mail-account-value
Source

get mail account value

Options: USER DOMAIN ACCOUNT KEY

Examples:


v-get-mail-account-value admin example.tld tester QUOTA
This function for getting a certain mail account parameter.

v-get-mail-domain-value
Source

get mail domain value

Options: USER DOMAIN KEY

Examples:


v-get-mail-domain-value admin example.com DKIM
This function for getting a certain mail domain parameter.

v-get-sys-timezone
Source

get system timezone

Options: [FORMAT]

This function to get system timezone

v-get-sys-timezones
Source

list system timezone

Options: [FORMAT]

Examples:


v-get-sys-timezones json
This function checks system timezone settings

v-get-user-salt
Source

get user salt

Options: USER [IP] [FORMAT]

Examples:


v-get-user-salt admin
This function provides users salt

v-get-user-value
Source

get user value

Options: USER KEY

Examples:


v-get-user-value admin FNAME
This function for obtaining certain user's parameters.

v-import-cpanel
Source

Import Cpanel backup to a new user

Options: BACKUP [MX]

Examples:


v-import-cpanel /backup/backup.tar.gz yes
Based on sk-import-cpanel-backup-to-vestacp Credits: Maks Usmanov (skamasle) and contributors: Thanks to https://github.com/Skamasle/sk-import-cpanel-backup-to-vestacp/graphs/contributors

v-import-database
Source

import database

Options: USER DB PATH

Examples:


v-import-database alice mydb /full/path/to.sql
This function for importing database.

v-import-directadmin
Source

Import DirectAdmin backup to a new user

Options:

Examples:


v-import-directadmin /backup/backup.tar.gz
Based on sk-da-importer Credits: Maks Usmanov (skamasle), Jaap Marcus (jaapmarcus) and contributors: Thanks to https://github.com/Skamasle/sk_da_importer/graphs/contributors

v-insert-dns-domain
Source

insert dns domain

Options: USER DATA [SRC] [FLUSH] #

This function inserts raw record to the dns.conf

v-insert-dns-record
Source

insert dns record

Options: USER DOMAIN DATA

This function inserts raw dns record to the domain conf

v-insert-dns-records
Source

inserts dns records

Options: USER DOMAIN DATA_FILE

This function copy dns record to the domain conf

v-list-access-key
Source

list all API access keys

Options: ACCESS_KEY_ID [FORMAT]

Examples:


v-list-access-key 1234567890ABCDefghij json
v-list-access-keys
Source

list all API access keys

Options: [FORMAT]

Examples:


v-list-access-keys json
v-list-api
Source

list api

Options: API [FORMAT]

Examples:


v-list-api mail-accounts json
v-list-apis
Source

list available APIs

Options: [FORMAT]

Examples:


v-list-apis json
v-list-backup-host
Source

list backup host

Options: TYPE [FORMAT]

Examples:


v-list-backup-host local
This function for obtaining the list of backup host parameters.

v-list-backup-host-restic
Source

list backup host

Options: TYPE [FORMAT]

Examples:


v-list-backup-host local
This function for obtaining the list of backup host parameters.

v-list-cron-job
Source

list cron job

Options: USER JOB [FORMAT]

Examples:


v-list-cron-job admin 7
This function of obtaining cron job parameters.

v-list-cron-jobs
Source

list user cron jobs

Options: USER [FORMAT]

Examples:


v-list-cron-jobs admin
This function for obtaining the list of all users cron jobs.

v-list-database
Source

list database

Options: USER DATABASE [FORMAT]

Examples:


v-list-database wp_db
This function for obtaining of all database's parameters.

v-list-database-host
Source

list database host

Options: TYPE HOST [FORMAT]

Examples:


v-list-database-host mysql localhost
This function for obtaining database host parameters.

v-list-database-hosts
Source

list database hosts

Options: [FORMAT]

Examples:


v-list-database-hosts json
This function for obtaining the list of all configured database hosts.

v-list-database-types
Source

list supported database types

Options: [FORMAT]

Examples:


v-list-database-types json
This function for obtaining the list of database types.

v-list-databases
Source

listing databases

Options: USER [FORMAT]

Examples:


v-list-databases user json
This function for obtaining the list of all user's databases.

v-list-default-php
Source

list default PHP version used by default.tpl

Options: [FORMAT]

List the default version used by the default template

v-list-dns-domain
Source

list dns domain

Options: USER DOMAIN [FORMAT]

Examples:


v-list-dns-domain alice wonderland.com
This function of obtaining the list of dns domain parameters.

v-list-dns-domains
Source

list dns domains

Options: USER [FORMAT]

Examples:


v-list-dns-domains admin
This function for obtaining all DNS domains of a user.

v-list-dns-records
Source

list dns domain records

Options: USER DOMAIN [FORMAT]

Examples:


v-list-dns-records admin example.com
This function for getting all DNS domain records.

v-list-dns-template
Source

list dns template

Options: TEMPLATE [FORMAT]

Examples:


v-list-dns-template zoho
This function for obtaining the DNS template parameters.

v-list-dns-templates
Source

list dns templates

Options: [FORMAT]

Examples:


v-list-dns-templates json
This function for obtaining the list of all DNS templates available.

v-list-dnssec-public-key
Source

list public dnssec key

Options: USER DOMAIN [FROMAT]

Examples:


v-list-dns-public-key admin acme.com
This function list the public key to be used with DNSSEC and needs to be added to the domain register.

v-list-firewall
Source

list iptables rules

Options: [FORMAT]

Examples:


v-list-firewall json
This function of obtaining the list of all iptables rules.

v-list-firewall-ban
Source

list firewall block list

Options: [FORMAT]

Examples:


v-list-firewall-ban json
This function of obtaining the list of currently blocked ips.

v-list-firewall-ipset
Source

List firewall ipset

Options: [FORMAT]

Examples:


v-list-firewall-ipset json
This function prints defined ipset lists

v-list-firewall-rule
Source

list firewall rule

Options: RULE [FORMAT]

Examples:


v-list-firewall-rule 2
This function of obtaining firewall rule parameters.

v-list-fs-directory
Source

list directory

Options: USER DIRECTORY

Examples:


v-list-fs-directory /home/admin/web
This function lists directory on the file system

v-list-letsencrypt-user
Source

list letsencrypt key

Options: USER [FORMAT]

Examples:


v-list-letsencrypt-user admin
This function for obtaining the letsencrypt key thumbprint

v-list-mail-account
Source

list mail domain account

Options: USER DOMAIN ACCOUNT [FORMAT]

Examples:


v-list-mail-account admin domain.tld tester
This function of obtaining the list of account parameters.

v-list-mail-account-autoreply
Source

list mail account autoreply

Options: USER DOMAIN ACCOUNT [FORMAT]

Examples:


v-list-mail-account-autoreply admin example.com testing
This function of obtaining mail account autoreply message.

v-list-mail-accounts
Source

list mail domain accounts

Options: USER DOMAIN [FORMAT]

Examples:


v-list-mail-accounts admin acme.com
This function of obtaining the list of all user domains.

v-list-mail-domain
Source

list mail domain

Options: USER DOMAIN [FORMAT]

Examples:


v-list-mail-domain user01 mydomain.com
This function of obtaining the list of domain parameters.

v-list-mail-domain-dkim
Source

list mail domain dkim

Options: USER DOMAIN [FORMAT]

Examples:


v-list-mail-domain-dkim admin maildomain.tld
This function of obtaining domain dkim files.

v-list-mail-domain-dkim-dns
Source

list mail domain dkim dns records

Options: USER DOMAIN [FORMAT]

Examples:


v-list-mail-domain-dkim-dns admin example.com
This function of obtaining domain dkim dns records for proper setup.

v-list-mail-domain-ssl
Source

list mail domain ssl certificate

Options: USER DOMAIN [FORMAT]

Examples:


v-list-mail-domain-ssl user acme.com json
This function of obtaining domain ssl files.

v-list-mail-domains
Source

list mail domains

Options: USER [FORMAT]

Examples:


v-list-mail-domains admin
This function of obtaining the list of all user domains.

v-list-remote-dns-hosts
Source

list remote dns host

Options: [FORMAT]

Examples:


v-list-remote-dns-hosts json
This function for obtaining the list of remote dns host.

v-list-sys-clamd-config
Source

list clamd config parameters

Options: [FORMAT]

This function for obtaining the list of clamd config parameters.

v-list-sys-config
Source

list system configuration

Options: [FORMAT]

Examples:


v-list-sys-config json
This function for obtaining the list of system parameters.

v-list-sys-cpu-status
Source

list system cpu info

Options:

options:

v-list-sys-db-status
Source

list db status

Options:

options:

v-list-sys-disk-status
Source

list disk information

Options:

options:

v-list-sys-dns-status
Source

list dns status

Options:

options:

v-list-sys-dovecot-config
Source

list dovecot config parameters

Options: [FORMAT]

This function for obtaining the list of dovecot config parameters.

v-list-sys-hestia-autoupdate
Source

list hestia autoupdate settings

Options: [FORMAT]

This function for obtaining autoupdate settings.

v-list-sys-hestia-ssl
Source

list hestia ssl certificate

Options: [FORMAT]

This function of obtaining hestia ssl files.

v-list-sys-hestia-updates
Source

list system updates

Options: [FORMAT]

This function checks available updates for hestia packages.

v-list-sys-info
Source

list system os

Options: [FORMAT]

This function checks available updates for hestia packages.

v-list-sys-interfaces
Source

list system interfaces

Options: [FORMAT]

This function for obtaining the list of network interfaces.

v-list-sys-ip
Source

list system IP

Options: IP [FORMAT]

Examples:


v-list-sys-ip 203.0.113.1
This function for getting the list of system IP parameters.

v-list-sys-ips
Source

list system IPs

Options: [FORMAT]

This function for obtaining the list of system IP addresses.

v-list-sys-languages
Source

list system languages

Options: [FORMAT]

Examples:


v-list-sys-languages json
This function for obtaining the available languages for HestiaCP Output is always in the ISO language code

v-list-sys-mail-status
Source

list mail status

Options:

options:

v-list-sys-memory-status
Source

list virtual memory info

Options:

options:

v-list-sys-mysql-config
Source

list mysql config parameters

Options: [FORMAT]

This function for obtaining the list of mysql config parameters.

v-list-sys-network-status
Source

list system network status

Options:

options:

v-list-sys-nginx-config
Source

list nginx config parameters

Options: [FORMAT]

This function for obtaining the list of nginx config parameters.

v-list-sys-pgsql-config
Source

list postgresql config parameters

Options: [FORMAT]

This function for obtaining the list of postgresql config parameters.

v-list-sys-php
Source

listing available PHP versions installed

Options: [FORMAT]

List /etc/php/* version check if folder fpm is available

v-list-sys-php-config
Source

list php config parameters

Options: [FORMAT]

This function for obtaining the list of php config parameters.

v-list-sys-proftpd-config
Source

list proftpd config parameters

Options: [FORMAT]

This function for obtaining the list of proftpd config parameters.

v-list-sys-rrd
Source

list system rrd charts

Options: [FORMAT]

List available rrd graphics, its titles and paths.

v-list-sys-services
Source

list system services

Options: [FORMAT]

Examples:


v-list-sys-services json
This function for obtaining the list of configured system services.

v-list-sys-shells
Source

list system shells

Options: [FORMAT]

This function for obtaining the list of system shells.

v-list-sys-spamd-config
Source

list spamassassin config parameters

Options: [FORMAT]

This function for obtaining the list of spamassassin config parameters.

v-list-sys-sshd-port
Source

list sshd port

Options: [FORMAT]

This function for obtainings the port of sshd listens to

v-list-sys-themes
Source

list system themes

Options: [FORMAT]

This function for obtaining the list of themes in the theme library and displaying them in the backend or user interface.

v-list-sys-users
Source

list system users

Options: [FORMAT]

This function for obtaining the list of system users without detailed information.

v-list-sys-vsftpd-config
Source

list vsftpd config parameters

Options: [FORMAT]

This function for obtaining the list of vsftpd config parameters.

v-list-sys-web-status
Source

list web status

Options:

options:

v-list-sys-webmail
Source

listing available webmail clients

Options: [FORMAT]

List available webmail clients

v-list-user
Source

list user parameters

Options: USER [FORMAT]

Examples:


v-list-user admin
This function to obtain user parameters.

v-list-user-auth-log
Source

list user log

Options: USER [FORMAT]

This function of obtaining the list of 10 last users commands.

v-list-user-backup
Source

list user backup

Options: USER BACKUP [FORMAT]

Examples:


v-list-user-backup admin admin.2019-05-19_03-31-30.tar
This function of obtaining the list of backup parameters. This call, just as all vlist* calls, supports 3 formats - json, shell and plain.

v-list-user-backup-exclusions
Source

list backup exclusions

Options: USER [FORMAT]

Examples:


v-list-user-backup-exclusions admin
This function for obtaining the backup exclusion list

v-list-user-backup-restic
Source

backup system user with all its objects

Options: USER NOTIFY

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-list-user-backups
Source

list user backups

Options: USER [FORMAT]

Examples:


v-list-user-backups admin
This function for obtaining the list of available user backups.

v-list-user-backups-restic
Source

backup system user with all its objects

Options: USER NOTIFY

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-list-user-files-restic
Source

backup system user with all its objects

Options: USER SNAPSHOT FOLDER

Examples:


v-backup-user admin yes
This function is used for backing up user with all its domains and databases.

v-list-user-ips
Source

list user IPs

Options: USER [FORMAT]

Examples:


v-list-user-ips admin
This function for obtaining the list of available IP addresses.

v-list-user-log
Source

list user log

Options: USER [FORMAT]

This function of obtaining the list of 100 last users commands.

v-list-user-notifications
Source

list user notifications

Options: USER [FORMAT]

Examples:


v-list-user-notifications admin
This function for getting the notifications list

v-list-user-ns
Source

list user nameservers

Options: USER [FORMAT]

Examples:


v-list-user-ns admin
Function for obtaining the list of user's DNS servers.

v-list-user-package
Source

list user package

Options: PACKAGE [FORMAT]

This function for getting the list of system ip parameters.

v-list-user-packages
Source

list user packages

Options: [FORMAT]

This function for obtaining the list of available hosting packages.

v-list-user-ssh-key
Source

add ssh key

Options: USER [FORMAT]

Lists $user/.ssh/authorized_keys

v-list-user-stats
Source

list user stats

Options: USER [FORMAT]

Examples:


v-list-user-stats admin
This function for listing user statistics

v-list-users
Source

list users

Options: [FORMAT]

This function to obtain the list of all system users.

v-list-users-stats
Source

list overall user stats

Options: [FORMAT]

This function for listing overall user statistics

v-list-web-domain
Source

list web domain parameters

Options: USER DOMAIN [FORMAT]

Examples:


v-list-web-domain admin example.com
This function to obtain web domain parameters.

v-list-web-domain-accesslog
Source

list web domain access log

Options: USER DOMAIN [LINES] [FORMAT]

Examples:


v-list-web-domain-accesslog admin example.com
This function of obtaining raw access web domain logs.

v-list-web-domain-errorlog
Source

list web domain error log

Options: USER DOMAIN [LINES] [FORMAT]

Examples:


v-list-web-domain-errorlog admin acme.com
This function of obtaining raw error web domain logs.

v-list-web-domain-ssl
Source

list web domain ssl certificate

Options: USER DOMAIN [FORMAT]

Examples:


v-list-web-domain-ssl admin wonderland.com
This function of obtaining domain ssl files.

v-list-web-domains
Source

list web domains

Options: USER [FORMAT]

Examples:


v-list-web-domains alice
This function to obtain the list of all user web domains.

v-list-web-stats
Source

list web statistics

Options: [FORMAT]

This function for obtaining the list of web statistics analyzer.

v-list-web-templates
Source

list web templates

Options: [FORMAT]

This function for obtaining the list of web templates available to a user.

v-list-web-templates-backend
Source

listing backend templates

Options: [FORMAT]

This function for obtaining the list of available backend templates.

v-list-web-templates-proxy
Source

listing proxy templates

Options: [FORMAT]

This function for obtaining the list of proxy templates available to a user.

v-log-action
Source

adds action event to user or system log

Options: LOG_TYPE USER

Event Levels: info, warning, error

v-log-user-login
Source

add user login

Options: USER IP STATUS [FINGERPRINT]

v-log-user-logout
Source

Log User logout event

Options: USER FINGERPRINT

v-move-fs-directory
Source

move file

Options: USER SRC_DIRECTORY DST_DIRECTORY

Examples:


v-move-fs-directory admin /home/admin/web /home/user02/
This function moved file or directory on the file system. This function can also be used to rename files just like normal mv command.

v-move-fs-file
Source

move file

Options: USER SRC_FILE DST_FILE

Examples:


v-move-fs-file admin readme.txt new_readme.txt
This function moved file or directory on the file system. This function can also be used to rename files just like normal mv command.

v-open-fs-config
Source

open config

Options: CONFIG

Examples:


v-open-fs-config /etc/mysql/my.cnf
This function opens/reads config files on the file system

v-open-fs-file
Source

open file

Options: USER FILE

Examples:


v-open-fs-file admin README.md
This function opens/reads files on the file system

v-purge-nginx-cache
Source

Purge nginx cache

Options: USER DOMAIN

Examples:


v-purge-nginx-cache user domain.tld
This function purges nginx cache.

v-quick-install-app
Source

Install Quick Install Web App via CLI

Options: ACTION [USER] [DOMAIN] [APP] [OPTIONS ...]

Examples:


v-quick-install-app install admin domain.com WordPress email="info@hestiacp" password="123456" username="admin" site_name="HestiaCP Demo" install_directory="/" language="nl_NL" php_version="8.2" database_create="true"
 example: v-quick-install-app app
 example: v-quick-install-app options admin domain.com WordPress
The v-quick-install-app install command is used to automate the installation of web applications on a server managed by Hestia Control Panel.
The v-quick-install-app app command is used to retrieve a list of web applications that can be quickly installed through the v-quick-install-app install command in the Hestia Control Panel. This command provides a convenient overview of supported applications and their versions, allowing users to choose which application they would like to deploy on their server. The names of the applications are case sensitive.
v-quick-install-app options admin domain.com WordPress list all the options available for the specified web application. This command provides a list of all the required and optional fields that need to be filled in when installing the application. The command also provides the default values for each field, if available.
v-rebuild-all
Source

rebuild all assets for a specified user

Options: USER [RESTART]

This function rebuilds all assets for a user account:

v-rebuild-cron-jobs
Source

rebuild cron jobs

Options: USER [RESTART]

Examples:


v-rebuild-cron-jobs admin yes
This function rebuilds system cron config file for specified user.

v-rebuild-database
Source

rebuild databases

Options: USER DATABASE

Examples:


v-rebuild-database user user_wordpress
This function for rebuilding a single database for a user

v-rebuild-databases
Source

rebuild databases

Options: USER

Examples:


v-rebuild-databases admin
This function for rebuilding of all databases of a single user.

v-rebuild-dns-domain
Source

rebuild dns domain

Options: USER DOMAIN [RESTART] [UPDATE_SERIAL]

Examples:


v-rebuild-dns-domain alice wonderland.com
This function rebuilds DNS configuration files.

v-rebuild-dns-domains
Source

rebuild dns domains

Options: USER [RESTART] [UPDATE_SERIAL]

Examples:


v-rebuild-dns-domains alice
This function rebuilds DNS configuration files.

v-rebuild-mail-domain
Source

rebuild mail domain

Options: USER DOMAIN

Examples:


v-rebuild-mail-domain user domain.tld
This function rebuilds configuration files for a single domain.

v-rebuild-mail-domains
Source

rebuild mail domains

Options: USER

Examples:


v-rebuild-mail-domains admin
This function rebuilds EXIM configuration files for all mail domains.

v-rebuild-user
Source

rebuild system user

Options: USER [RESTART]

Examples:


v-rebuild-user admin yes
This function rebuilds system user account.

v-rebuild-users
Source

rebuild system users

Options: [RESTART]

This function rebuilds user configuration for all users.

v-rebuild-web-domain
Source

rebuild web domain

Options: USER DOMAIN [RESTART]

Examples:


v-rebuild-web-domain user domain.tld
This function rebuilds web configuration files.

v-rebuild-web-domains
Source

rebuild web domains

Options: USER [RESTART]

This function rebuilds web configuration files.

v-refresh-sys-theme
Source

change active system theme

Options: –

This function for changing the currently active system theme.

v-rename-user-package
Source

change package name

Options: OLD_NAME NEW_NAME [MODE]

Examples:


v-rename-package package package2
This function changes the name of an existing package.

v-repair-sys-config
Source

Restore system configuration

Options: [SYSTEM]

This function repairs or restores the system configuration file.

v-restart-cron
Source

restart cron service

Options: –

This function tells crond service to reread its configuration files.

v-restart-dns
Source

restart dns service

Options: –

This function tells BIND service to reload dns zone files.

v-restart-ftp
Source

restart ftp service

Options: –

This function tells ftp server to reread its configuration.

v-restart-mail
Source

restart mail service

Options: [RESTART]

This function tells exim or dovecot services to reload configuration files.

v-restart-proxy
Source

restart proxy server

Options: –

Examples:


v-restart-proxy [RESTART]
This function reloads proxy server configuration.

v-restart-service
Source

restart service

Options: SERVICE [RESTART]

Examples:


v-restart-service apache2
This function restarts system service.

v-restart-system
Source

restart operating system

Options: RESTART [DELAY]

Examples:


v-restart-system yes
This function restarts operating system.

v-restart-web
Source

restart web server

Options: [RESTARRT]

This function reloads web server configuration.

v-restart-web-backend
Source

restart php interpreter

Options: –

This function reloads php interpreter configuration.

v-restore-cron-job
Source

restore single cron job

Options: USER BACKUP DOMAIN [NOTIFY]

Examples:


v-restore-cron-job USER BACKUP CRON [NOTIFY]
This function allows the user to restore a single cron job from a backup archive.

v-restore-cron-job-restic
Source

restore single cron job

Options: USER SNAPSHOT [NOTIFY]

Examples:


v-restore-cron-job USER BACKUP [NOTIFY]
This function allows the user to restore a cron jobs from a snapshot.

v-restore-database
Source

restore single database

Options: USER BACKUP DATABASE [NOTIFY]

Examples:


v-restore-database USER BACKUP DATABASE [NOTIFY]
This function allows the user to restore a single database from a backup archive.

v-restore-database-restic
Source

restore Database

Options: USER SNAPSHOT DATABASE

Examples:


v-restore-database-restic user snapshot user_database
example: v-restore-database-restic user snapshot 'user_database,user_database2'
example: v-restore-database-restic user snapshot '*'
This function for restoring database from restic snapshot.

v-restore-dns-domain
Source

restore single dns domain

Options: USER BACKUP DOMAIN [NOTIFY]

Examples:


v-restore-dns-domain USER BACKUP DOMAIN [NOTIFY]
This function allows the user to restore a single DNS domain from a backup archive.

v-restore-dns-domain-restic
Source

restore DNS domain

Options: USER SNAPSHOT DOMAIN

Examples:


v-restore-user user snapshot domain.com
This function for restoring database from restic snapshot.

v-restore-file-restic
Source

restore file or folder

Options: USER SNAPSHOT PATH

Examples:


v-restore-user user snapshot path
This function for restoring database from restic snapshot.

v-restore-mail-domain
Source

restore single mail domain

Options: USER BACKUP DOMAIN [NOTIFY]

Examples:


v-restore-mail-domain USER BACKUP DOMAIN [NOTIFY]
This function allows the user to restore a single mail domain from a backup archive.

v-restore-mail-domain-restic
Source

restore WEB domain

Options: USER SNAPSHOT DOMAIN

Examples:


v-restore-mail-domain-restic user snapshot domain.com
example: v-restore-mail-domain-restic user snapshot 'domain.com,domain2.com'
example: v-restore-mail-domain-restic user snapshot '*'
This function for restoring database from restic snapshot.

v-restore-user
Source

restore user

Options: USER BACKUP [WEB] [DNS] [MAIL] [DB] [CRON] [UDIR] [NOTIFY]

Examples:


v-restore-user admin 2019-04-22_01-00-00.tar
This function for restoring user from backup. To be able to restore the backup, the archive needs to be placed in /backup.

v-restore-user-full-restic
Source

restore user via Restic

Options: USER SNAPSHOT KEY

Examples:


v-restore-user-full-restic user snapshot key
Full user restore from a non existing user

v-restore-user-restic
Source

restore user via Restic

Options: USER SNAPSHOT WEB DNS MAIL DB CRON UDIR

Examples:


v-restore-user-restic user snapshot
This function for restoring database from restic snapshot.

v-restore-web-domain
Source

restore single web domain

Options: USER BACKUP DOMAIN [NOTIFY]

Examples:


v-restore-web-domain USER BACKUP DOMAIN [NOTIFY]
This function allows the user to restore a single web domain from a backup archive.

v-restore-web-domain-restic
Source

restore WEB domain

Options: USER SNAPSHOT DOMAIN

Examples:


v-restore-web-domain-restic user snapshot domain.com
example: v-restore-web-domain-restic user snapshot 'domain.com,domain2.com'
example: v-restore-web-domain-restic user snapsho '*'
This function for restoring database from restic snapshot.

v-revoke-api-key
Source

revokes api key

Options: [HASH]

Examples:


v-revoke-api-key mykey
This function removes a key from in $HESTIA/data/keys/

v-run-cli-cmd
Source

run cli command

Options: USER CMD [ARG...]

Examples:


v-run-cli-cmd user composer require package
This function runs a limited list of cli commands with dropped privileges as the specific hestia user

v-schedule-letsencrypt-domain
Source

adding cronjob for letsencrypt cetificate installation

Options: USER DOMAIN [ALIASES]

Examples:


v-schedule-letsencrypt-domain admin example.com www.example.com
This function adds cronjob for letsencrypt ssl certificate installation

v-schedule-user-backup
Source

schedule user backup creation

Options: USER

Examples:


v-schedule-user-backup admin
This function for scheduling user backup creation.

v-schedule-user-backup-download
Source

Schedule a backup

Options: USER BACKUP

Examples:


v-schedule-user-backup-download admin 2019-04-22_01-00-00.tar
This function for scheduling user backup creation.

v-schedule-user-backup-restic
Source

schedule user backup creation

Options: USER

Examples:


v-schedule-user-backup admin
This function for scheduling user backup creation.

v-schedule-user-restore
Source

schedule user backup restoration

Options: USER BACKUP [WEB] [DNS] [MAIL] [DB] [CRON] [UDIR]

Examples:


v-schedule-user-restore 2019-04-22_01-00-00.tar
This function for scheduling user backup restoration.

v-schedule-user-restore-restic
Source

schedule user backup restoration

Options: USER BACKUP [WEB] [DNS] [MAIL] [DB] [CRON] [UDIR]

Examples:


v-schedule-user-restore 2019-04-22_01-00-00.tar
This function for scheduling user backup restoration.

v-search-command
Source

search for available commands

Options: ARG1 [ARG...]

Examples:


v-search-command web
This function searches for available Hestia Control Panel commands and returns results based on the specified criteria. Originally developed for VestaCP by Federico Krum https://github.com/FastDigitalOceanDroplets/VestaCP/blob/master/files/v-search-command

v-search-domain-owner
Source

search domain owner

Options: DOMAIN [TYPE]

Examples:


v-search-domain-owner acme.com
This function that allows to find user objects.

v-search-fs-object
Source

search file or directory

Options: USER OBJECT [PATH]

Examples:


v-search-fs-object admin hello.txt
This function search files and directories on the file system

v-search-object
Source

search objects

Options: OBJECT [FORMAT]

Examples:


v-search-object example.com json
This function that allows to find system objects.

v-search-user-object
Source

search objects

Options: USER OBJECT [FORMAT]

Examples:


v-search-user-object admin example.com json
This function that allows to find user objects.

v-start-service
Source

start service

Options: SERVICE

Examples:


v-start-service mysql
This function starts system service.

v-stop-firewall
Source

stop system firewall

Options: –

This function stops iptables

v-stop-service
Source

stop service

Options: SERVICE

Examples:


v-stop-service apache2
This function stops system service.

v-suspend-cron-job
Source

suspend cron job

Options: USER JOB [RESTART]

Examples:


v-suspend-cron-job admin 5 yes
This function suspends a certain job of the cron scheduler.

v-suspend-cron-jobs
Source

Suspending sys cron jobs

Options: USER [RESTART]

Examples:


v-suspend-cron-jobs admin
This function suspends all user cron jobs.

v-suspend-database
Source

suspend database

Options: USER DATABASE

Examples:


v-suspend-database admin admin_wordpress_db
This function for suspending a certain user database.

v-suspend-database-host
Source

suspend database server

Options: TYPE HOST

Examples:


v-suspend-database-host mysql localhost
This function for suspending a database server.

v-suspend-databases
Source

suspend databases

Options: USER

Examples:


v-suspend-databases admin
This function for suspending of all databases of a single user.

v-suspend-dns-domain
Source

suspend dns domain

Options: USER DOMAIN [RESTART]

Examples:


v-suspend-dns-domain alice acme.com
This function suspends a certain user's domain.

v-suspend-dns-domains
Source

suspend dns domains

Options: USER [RESTART]

Examples:


v-suspend-dns-domains admin yes
This function suspends all user's DNS domains.

v-suspend-dns-record
Source

suspend dns domain record

Options: USER DOMAIN ID [RESTART]

Examples:


v-suspend-dns-record alice wonderland.com 42 yes
This function suspends a certain domain record.

v-suspend-domain
Source

suspend web/dns/mail domain

Options: USER DOMAIN

Examples:


v-suspend-domain admin example.com
This function suspends web/dns/mail domain.

v-suspend-firewall-rule
Source

suspend firewall rule

Options: RULE

Examples:


v-suspend-firewall-rule 7
This function suspends a certain firewall rule.

v-suspend-mail-account
Source

suspend mail account

Options: USER DOMAIN ACCOUNT

Examples:


v-suspend-mail-account admin acme.com bob
This function suspends mail account.

v-suspend-mail-accounts
Source

suspend all mail domain accounts

Options: USER DOMAIN

Examples:


v-suspend-mail-accounts admin example.com
This function suspends all mail domain accounts.

v-suspend-mail-domain
Source

suspend mail domain

Options: USER DOMAIN

Examples:


v-suspend-mail-domain admin domain.com
This function suspends mail domain.

v-suspend-mail-domains
Source

suspend mail domains

Options: USER

Examples:


v-suspend-mail-domains admin
This function suspends all user's MAIL domains.

v-suspend-remote-dns-host
Source

suspend remote dns server

Options: HOST

Examples:


v-suspend-remote-dns-host hostname.tld
This function for suspending remote dns server.

v-suspend-user
Source

suspend user

Options: USER [RESTART]

Examples:


v-suspend-user alice yes
This function suspends a certain user and all his objects.

v-suspend-web-domain
Source

suspend web domain

Options: USER DOMAIN [RESTART]

Examples:


v-suspend-web-domain admin example.com yes
This function for suspending the site's operation. After blocking it all visitors will be redirected to a web page explaining the reason of suspend. By blocking the site the content of all its directories remains untouched.

v-suspend-web-domains
Source

suspend web domains

Options: USER [RESTART]

Examples:


v-suspend-web-domains bob
This function of suspending all user's sites.

v-sync-dns-cluster
Source

synchronize dns domains

Options: HOST

This function synchronise all dns domains.

v-unsuspend-cron-job
Source

unsuspend cron job

Options: USER JOB [RESTART]

Examples:


v-unsuspend-cron-job admin 7 yes
This function unsuspend certain cron job.

v-unsuspend-cron-jobs
Source

unsuspend sys cron

Options: USER [RESTART]

Examples:


v-unsuspend-cron-jobs admin no
This function unsuspends all suspended cron jobs.

v-unsuspend-database
Source

unsuspend database

Options: USER DATABASE

Examples:


v-unsuspend-database admin mydb
This function for unsuspending database.

v-unsuspend-database-host
Source

unsuspend database server

Options: TYPE HOST

Examples:


v-unsuspend-database-host mysql localhost
This function for unsuspending a database server.

v-unsuspend-databases
Source

unsuspend databases

Options: USER

This function for unsuspending all user's databases.

v-unsuspend-dns-domain
Source

unsuspend dns domain

Options: USER DOMAIN

Examples:


v-unsuspend-dns-domain alice wonderland.com
This function unsuspends a certain user's domain.

v-unsuspend-dns-domains
Source

unsuspend dns domains

Options: USER [RESTART]

Examples:


v-unsuspend-dns-domains alice
This function unsuspends all user's DNS domains.

v-unsuspend-dns-record
Source

unsuspend dns domain record

Options: USER DOMAIN ID [RESTART]

Examples:


v-unsuspend-dns-record admin example.com 33
This function unsuspends a certain domain record.

v-unsuspend-domain
Source

unsuspend web/dns/mail domain

Options: USER DOMAIN

Examples:


v-unsuspend-domain admin acme.com
This function unsuspends web/dns/mail domain.

v-unsuspend-firewall-rule
Source

unsuspend firewall rule

Options: RULE

Examples:


v-unsuspend-firewall-rule 7
This function unsuspends a certain firewall rule.

v-unsuspend-mail-account
Source

unsuspend mail account

Options: USER DOMAIN ACCOUNT

Examples:


v-unsuspend-mail-account admin acme.com tester
This function unsuspends mail account.

v-unsuspend-mail-accounts
Source

unsuspend all mail domain accounts

Options: USER DOMAIN

Examples:


v-unsuspend-mail-accounts admin acme.com
This function unsuspends all mail domain accounts.

v-unsuspend-mail-domain
Source

unsuspend mail domain

Options: USER DOMAIN

Examples:


v-unsuspend-mail-domain user02 acme.com
This function unsuspends mail domain.

v-unsuspend-mail-domains
Source

unsuspend mail domains

Options: USER

Examples:


v-unsuspend-mail-domains admin
This function unsuspends all user's MAIL domains.

v-unsuspend-remote-dns-host
Source

unsuspend remote dns server

Options: HOST

Examples:


v-unsuspend-remote-dns-host hosname.com
This function for unsuspending remote dns server.

v-unsuspend-user
Source

unsuspend user

Options: USER [RESTART]

Examples:


v-unsuspend-user bob
This function unsuspends user and all his objects.

v-unsuspend-web-domain
Source

unsuspend web domain

Options: USER DOMAIN [RESTART]

Examples:


v-unsuspend-web-domain admin acme.com
This function of unsuspending the domain.

v-unsuspend-web-domains
Source

unsuspend web domains

Options: USER [RESTART]

Examples:


v-unsuspend-web-domains admin
This function of unsuspending all user's sites.

v-update-database-disk
Source

update database disk usage

Options: USER DATABASE

Examples:


v-update-database-disk admin wp_db
This function recalculates disk usage for specific database.

v-update-databases-disk
Source

update databases disk usage

Options: USER

Examples:


v-update-databases-disk admin
This function recalculates disk usage for all user databases.

v-update-dns-templates
Source

update dns templates

Options: [RESTART]

This function for obtaining updated dns templates from Hestia package.

v-update-firewall
Source

update system firewall rules

Options: –

This function updates iptables rules

v-update-firewall-ipset
Source

update firewall ipset

Options: [REFRESH]

This function creates ipset lists and updates the lists if they are expired or ondemand

v-update-host-certificate
Source

update host certificate for hestia

Options: USER HOSTNAME

Examples:


v-update-host-certificate admin example.com
This function updates the SSL certificate used for Hestia Control Panel.

v-update-letsencrypt-ssl
Source

update letsencrypt ssl certificates

Options: –

This function for renew letsencrypt expired ssl certificate for all users

v-update-mail-domain-disk
Source

update mail domain disk usage

Options: USER DOMAIN

Examples:


v-update-mail-domain-disk admin example.com
This function updates domain disk usage.

v-update-mail-domain-ssl
Source

updating ssl certificate for domain

Options: USER DOMAIN SSL_DIR [RESTART]

Examples:


v-update-mail-domain-ssl admin domain.com /home/admin/tmp
This function updates the SSL certificate for a domain. Parameter ssl_dir is a path to directory where 2 or 3 ssl files can be found. Certificate file domain.tld.crt and its key domain.tld.key are mandatory. Certificate authority domain.tld.ca file is optional.

v-update-mail-domains-disk
Source

calculate disk usage for all mail domains

Options: USER

Examples:


v-update-mail-domains-disk admin
This function calculates disk usage for all mail domains.

v-update-mail-templates
Source

update mail templates

Options: [RESTART] [SKIP]

This function for obtaining updated webmail templates from Hestia package.

v-update-sys-defaults
Source

update default key database

Options: [SYSTEM]

Examples:


v-update-sys-defaults
example: v-update-sys-defaults user
This function updates the known key/value pair database

v-update-sys-hestia
Source

update hestia package/configs

Options: PACKAGE

Examples:


v-update-sys-hestia hestia-php
This function runs as apt update trigger. It pulls shell script from hestia server and runs it. (hestia, hestia-nginx and hestia-php are valid options)

v-update-sys-hestia-all
Source

update all hestia packages

Options: –

This function of updating all hestia packages

v-update-sys-hestia-git
Source

Install update from Git repository

Options: REPOSITORY BRANCH INSTALL

Examples:


v-update-sys-hestia-git hestiacp staging/beta install
# Will download from the hestiacp repository
# Pulls code from staging/beta branch
# install: installs package immediately
# install-auto: installs package and schedules automatic updates from Git
Downloads and compiles/installs packages from GitHub repositories

v-update-sys-ip
Source

update system IP

Options: –

Examples:


v-update-sys-ip
# Intended for internal usage
This function scans configured IP in the system and register them with Hestia internal database. This call is intended for use on vps servers, where IP is set by hypervisor.

v-update-sys-ip-counters
Source

update IP usage counters

Options: IP

Function updates usage U_WEB_ADOMAINS and U_SYS_USERS counters.

v-update-sys-queue
Source

update system queue

Options: PIPE

This function is responsible queue processing. Restarts of services, scheduled backups, web log parsing and other heavy resource consuming operations are handled by this script. It helps to optimize system behaviour. In a nutshell Apache will be restarted only once even if 10 domains are added or deleted.

v-update-sys-rrd
Source

update system rrd charts

Options: –

This function is wrapper for all rrd functions. It updates all v-update-sys-rrd_* at once.

v-update-sys-rrd-apache2
Source

update apache2 rrd

Options: PERIOD

This function is for updating apache rrd database and graphic.

v-update-sys-rrd-ftp
Source

update ftp rrd

Options: PERIOD

This function is for updating ftpd rrd database and graphic.

v-update-sys-rrd-httpd
Source

update httpd rrd

Options: PERIOD

This function is for updating apache rrd database and graphic.

v-update-sys-rrd-la
Source

update load average rrd

Options: PERIOD

This function is for updating load average rrd database and graphic.

v-update-sys-rrd-mail
Source

update mail rrd

Options: PERIOD

This function is for updating mail rrd database and graphic.

v-update-sys-rrd-mem
Source

update memory rrd

Options: PERIOD

This function is for updating memory rrd database and graphic.

v-update-sys-rrd-mysql
Source

update MySQL rrd

Options: PERIOD

This function is for updating mysql rrd database and graphic.

v-update-sys-rrd-net
Source

update network rrd

Options: PERIOD

This function is for updating network usage rrd database and graphic.

v-update-sys-rrd-nginx
Source

update nginx rrd

Options: PERIOD

This function is for updating nginx rrd database and graphic.

v-update-sys-rrd-pgsql
Source

update PostgreSQL rrd

Options: PERIOD

This function is for updating postgresql rrd database and graphic.

v-update-sys-rrd-ssh
Source

update ssh rrd

Options: PERIOD

This function is for updating ssh rrd database and graphic.

v-update-user-backup-exclusions
Source

update backup exclusion list

Options: USER FILE

Examples:


v-update-user-backup-exclusions admin /tmp/backup_exclusions
This function for updating backup exclusion list

v-update-user-cgroup
Source

update user disk quota

Options: USER

Examples:


v-update-user-cgroup admin
The functions upates cgroup, cpu, ram ,... for specific user

v-update-user-counters
Source

update user usage counters

Options: USER

Examples:


v-update-user-counters admin
Function updates usage counters like U_WEB_DOMAINS, U_MAIL_ACCOUNTS, etc.

v-update-user-disk
Source

update user disk usage

Options: USER

Examples:


v-update-user-disk admin
The functions recalculates disk usage and updates database.

v-update-user-package
Source

update user package

Options: PACKAGE

Examples:


v-update-user-package default
This function propagates package to connected users.

v-update-user-quota
Source

update user disk quota

Options: USER

Examples:


v-update-user-quota alice
The functions upates disk quota for specific user

v-update-user-stats
Source

update user statistics

Options: USER

Examples:


v-update-user-stats admin
Function logs user parameters into statistics database.

v-update-web-domain-disk
Source

update disk usage for domain

Options: USER DOMAIN

Examples:


v-update-web-domain-disk alice wonderland.com
This function recalculates disk usage for specific webdomain.

v-update-web-domain-ssl
Source

updating ssl certificate for domain

Options: USER DOMAIN SSL_DIR [RESTART]

Examples:


v-update-web-domain-ssl admin domain.com /home/admin/tmp
This function updates the SSL certificate for a domain. Parameter ssl_dir is a path to directory where 2 or 3 ssl files can be found. Certificate file domain.tld.crt and its key domain.tld.key are mandatory. Certificate authority domain.tld.ca file is optional.

v-update-web-domain-stat
Source

update domain statistics

Options: USER DOMAIN

Examples:


v-update-web-domain-stat alice acme.com
This function runs log analyser for specific webdomain.

v-update-web-domain-traff
Source

update domain bandwidth usage

Options: USER DOMAIN

Examples:


v-update-web-domain-traff admin example.com
This function recalculates bandwidth usage for specific domain.

v-update-web-domains-disk
Source

update domains disk usage

Options: USER

Examples:


v-update-web-domains-disk alice
This function recalculates disk usage for all user webdomains.

v-update-web-domains-stat
Source

update domains statistics

Options: USER

Examples:


v-update-web-domains-stat admin
This function runs log analyser usage for all user webdomains.

v-update-web-domains-traff
Source

update domains bandwidth usage

Options: USER

Examples:


v-update-web-domains-traff bob
This function recalculates bandwidth usage for all user webdomains.

v-update-web-templates
Source

update web templates

Options: [RESTART] [SKIP]

This function for obtaining updated web (Nginx/Apache2/PHP) templates from the Hestia package.

v-update-white-label-logo
Source

update white label logo's

Options: [DOWNLOAD]

Replace Hestia logos with User created logo's

