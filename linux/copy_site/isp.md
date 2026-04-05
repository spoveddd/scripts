https://www.ispmanager.ru/docs/developer-guide/mgrctl
Утилита mgrctl предназначена для выполнения операций с панелью управления и вызова её функций из командной строки. По умолчанию она расположена в /usr/local/mgr5/sbin/mgrctl.

Синтаксис
/usr/local/mgr5/sbin/mgrctl [-m <manager>] [-u | -i [lang=<language>] | -l | [[-o <output format>] [-R | <funcname> [[<param>=<value>] ...]] [[-e ‘<param>=$<ENV_NAME>’] ...]]]
-m — определяет, к какой панели управления относится команда. После ключа укажите сокращённое название панели управления:

ispmgr — ispmanager;
-i — краткая информация обо всех возможных функциях панели управления. Если указана функция , то будет отображена краткая информация обо всех параметрах этой функции. Если указан параметр lang, то информация будет отображена на выбранном языке . Доступные значения: ru, en. По умолчанию — ru.

-o — формат вывода информации. Доступные значения: text, xml, devel, json. По умолчанию — text.

-l — приостановить работу панели управления. Панель управления останавливается вызовом функции exit. Блокируется возможность её повторного запуска.

Обратите внимание!
Если приостанавливается работа COREmanager, то приостанавливается работа всех панелей управления на сервере. После возобновления работы COREmanager будет возобновлена работа остальных панелей управления на сервере.
-u — возобновить работу панели управления, приостановленной при помощи ключа -l.

Обратите внимание!
В случае, если:
Командой mgrctl -m -l поочерёдно приостановлена работа нескольких панелей управления на сервере, включая COREmanager.
Командой mgrctl -m core -u возобновляется работа COREmanager.
Работа остальных панелей управления не будет возобновлена.
-R — перезапустить панель управления перед выполнением функции.

— имя функции.

= — параметр функции и его значение.

-e ‘=$’  — параметры, передаваемые через переменные окружения

Передача параметров через переменные окружения


Обратите внимание!
Функция доступна в версии COREmanager 5.325 и выше.
Чтобы передать секретные данные в параметрах mrgctl, вы можете использовать переменные окружения. Для этого запустите утилиту с параметром 

 -e ‘<param>=$<ENV_NAME>’
Пояснения
— имя параметра — имя переменной окружения
Обратите внимание!
Укажите перед именем переменной знак $ и заэкранируйте аргумент =$.
Пример передачи пароля
Задайте значение пароля в переменной окружения SECRET_PASSWORD: 
export SECRET_PASSWORD=secret

Создайте в ispmanager пользователя для FTP: 
/usr/local/mgr5/sbin/mgrctl -m ispmgr ftp.user.edit name=ftpuser home=/ owner=www-root -e 'passwd=$SECRET_PASSWORD' sok=ok
Примеры использования
Общие примеры
Завершение работы панели управления

/usr/local/mgr5/sbin/mgrctl -m <manager> exit
Список всех доступных функций mgrctl для панели управления

/usr/local/mgr5/sbin/mgrctl -m <manager> -i
Список параметров определённой функции панели управления

/usr/local/mgr5/sbin/mgrctl -m <manager> -i funcname lang=ru
Примеры для ispmanager
Получить список всех сайтов

/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain  | sed 's/=/ /' | awk '{print $2}'
Список сайтов, принадлежащих определённому пользователю

/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain  su=<user>  | sed 's/=/ /' | awk '{print $2}'
Пояснения
— имя пользователя в ispmanager.
Обновить все домены на внешних серверах имён

for i in $(/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain | awk '{print $1}' | awk -F = '{print $2}'); do /usr/local/mgr5/sbin/mgrctl -m ispmgr domain.fix elid=$i; done
Отключить PHP для всех сайтов

for i in $(/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain | awk '{print $1}' | awk -F = '{print $2}'); do /usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.edit php=off elid=$i sok=ok; done


[root@easy0388 ~]# /usr/local/mgr5/sbin/mgrctl -m ispmgr -i
acmesh.certs.update                          Description is not available
actionlist                                   Description is not available
addsorter                                    Function type: form
admin                                        Administrators . Function type: list
admin.delete                                 Delete. Delete administrator. Function type:
                                             group operation
admin.edit                                   Administrator . Create administrator . Create
                                             administrator. Function type: form
admin.filter                                 Administrators' list filter . Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
admin.resume                                 Enable. Enable administrator. Function type:
                                             group operation
admin.suspend                                Disable. Disable administrator. Function type:
                                             group operation
adminstat                                    Limits. Function type: list
adminstat.delete                             Function type: group operation
adminstat.details                            Resource information . Details. Detailed
                                             information related to the selected resource
                                             type. Function type: list
adminstat.details.delete                     Function type: group operation
adminstat.details.edit                       Function type: form
adminstat.edit                               Function type: form
afterinstall                                 Description is not available
afterupdate                                  Description is not available
agreement                                    Function type: list
antivirus_redirect                           Description is not available
apache.instance.list                         Description is not available
apache.instance.remove                       Description is not available
apache.restart                               Description is not available
aps.cache                                    Description is not available
aps.catalog                                  Web scripts. Function type: list
aps.catalog.apps                             Web script packages. Function type: list
aps.catalog.apps.default                     Default application. The application will be
                                             used by default on "Quick install"
aps.catalog.apps.delete                      Function type: group operation
aps.catalog.apps.edit                        Web script. Description. Package information .
                                             Function type: form
aps.catalog.apps.resume                      Allow. Allow users to install this package.
                                             Function type: group operation
aps.catalog.apps.suspend                     Forbid. Forbid users to use this package.
                                             Function type: group operation
aps.choosever                                Select the web script package version. Function
                                             type: form
aps.install                                  Function type: form
aps.install.execute                          Confirm. Function type: form
aps.install.license                          License agreement. Function type: form
aps.install.settings                         Installation parameters. Function type: form
aps.install.start                            Web script. Function type: form
aps.user_catalog                             Function type: form
auth                                         Description is not available
authenticate.email.isowner                   Description is not available
authenticate.email.setpass                   Description is not available
authenticate.internal.isowner                Description is not available
authenticate.internal.setpass                Description is not available
authenticate.pam.isowner                     Description is not available
authenticate.pam.setpass                     Description is not available
authenticate.system.isowner                  Description is not available
authenticate.system.setpass                  Description is not available
authenticate.unixsysuser.isowner             Description is not available
authenticate.unixsysuser.setpass             Description is not available
authlog                                      Access log. Function type: list
authlog.filter                               Access log filter. Filter. Filter the list.
                                             Function type: form
autodomain.bind                              Description is not available
backup2.backup.report                        Backup error log. Function type: list
backup2.backup.report.details                Viewing the backup error log. Details. View the
                                             record. Function type: form
backup2.backup.report.filter                 Backup error log. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
backup2.backup.report.last                   Backup error log. Function type: list
backup2.cache.clear                          Description is not available
backup2.db                                   Description is not available
backup2.download                             Description is not available
backup2.finish                               Description is not available
backup2.import.fail                          Description is not available
backup2.import.finish                        Description is not available
backup2.item                                 Description is not available
backup2.item.info                            Description is not available
backup2.list                                 Backup archives. Function type: list
backup2.list.db                              Backup copies . Function type: list
backup2.list.db.restore                      Restore. Restore the selected database.
backup2.list.delete                          Delete. Delete the backup copy from the custom
                                             storage . Function type: group operation
backup2.list.disabled                        Backups. Function type: form
backup2.list.download                        Enter password . Download. Download the
                                             selected backup.. Function type: form
backup2.list.files                           Backup copies . Function type: list
backup2.list.files.restore                   Restore. Restore the selected file or folder.
backup2.list.import                          User import . Function type: form
backup2.list.new.user                        Description is not available
backup2.list.restore.password                Enter password . Function type: form
backup2.list.type                            Backup archive . Details. View the content of
                                             the selected backup.. Function type: list
backup2.list.type.download                   Enter password . Function type: form
backup2.metadata                             Description is not available
backup2.metadata.site                        Description is not available
backup2.report                               Recovery report . Function type: list
backup2.report.details                       Viewing the recovery error log. Details. View
                                             the record. Function type: form
backup2.rescan                               Description is not available
backup2.restore.user.email                   Description is not available
backup2.schedule                             Schedule. Function type: form
backup2.settings                             Function type: form
backup2.site.info                            Description is not available
backup2.site.status                          Description is not available
backup2.superlist                            Backup copies. Function type: list
backup2.superlist.delete                     Delete. Delete backup copy. Function type:
                                             group operation
backup2.superlist.download                   Enter password . Function type: form
backup2.superlist.import                     User import . Function type: form
backup2.superlist.new.all                    Description is not available
backup2.superlist.new.settings               Description is not available
backup2.superlist.new.users                  Create backup copy. Function type: form
backup2.superlist.roots                      Saved data . Function type: list
backup2.superlist.roots.download             Function type: form
backup2.superlist.roots.restore              Description is not available
backup2.superlist.roots.undo                 Description is not available
backup2.superlist.users                      Backup copies . View files. View the list of
                                             users whose files are saved to backup. Function
                                             type: list
backup2.superlist.users.delete               Delete. Delete user account backup copy.
                                             Function type: group operation
backup2.superlist.users.password             Enter password . Function type: form
backup2.superlist.users.redirect             List. View the list of backups
backup2.superlist.users.restore2             Restore. Restore user data . Function type:
                                             group operation
backup2.superlist.users.restoreas            User recovery . Restore as. Restore deleted
                                             user. Function type: form
backup2.superlist.users.roots                Saved data . Function type: list
backup2.superlist.users.single               Function type: form
backup2.superlist.users.su                   Description is not available
backup2.superlist.users.type                 Backup archive . Function type: list
backup2.superlist.users.type.db              Backup copies . Databases . Open an overview of
                                             the databases that are included in the backup
                                             archive.. Function type: list
backup2.superlist.users.type.db.restore      Restore. Restore the selected database..
                                             Function type: group operation
backup2.superlist.users.type.download        Function type: form
backup2.superlist.users.type.files           Backup copies . Files. Open an overview of the
                                             files that are included in the backup archive..
                                             Function type: list
backup2.superlist.users.type.files.restore   Restore. Restore the selected file or folder..
                                             Function type: group operation
backup2.users.finalize                       Description is not available
beforeremove                                 Description is not available
blacklist                                    Blacklist. Function type: list
blacklist.delete                             Delete. Delete rule. Function type: group
                                             operation
blacklist.edit                               Blacklist rule. Create rule. Add a rule to the
                                             blacklist. Function type: form
brand                                        Branding settings. Function type: form
brandlist                                    Branding settings. Function type: list
brandlist.delete                             Delete. Delete . Function type: group operation
brandlist.edit                               Branding settings. Add. Add. Function type:
                                             form
brandlist.fix                                Fix. Form the icons and css files for all the
                                             settings
bugtrack                                     Function type: none
cache.accesslog.size                         Description is not available
changelog                                    Change log. Function type: list
changelog.changes                            Version changes . Changes . View the change log
                                             in the selected version . Function type: list
changelog.changes.mgr                        Function type: list
changelog.filter                             Change log filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
changelog.refresh                            Update. Update the list of versions
check.alphanum                               Function type: validator
check.alphanumspace                          Function type: validator
check.ascii                                  Function type: validator
check.caa_value_domain                       Function type: validator
check.caa_value_email                        Function type: validator
check.ccode                                  Function type: validator
check.date                                   Function type: validator
check.datetime                               Function type: validator
check.dbaddr                                 Function type: validator
check.dbname                                 Function type: validator
check.domain                                 Function type: validator
check.domain_or_ip                           Function type: validator
check.domainrecordname                       Function type: validator
check.domaintxt                              Function type: validator
check.ds_algorithm                           Function type: validator
check.ds_digest_type                         Function type: validator
check.email                                  Function type: validator
check.emailbl                                Function type: validator
check.emailname                              Function type: validator
check.emailsender                            Function type: validator
check.float                                  Function type: validator
check.googledrivepath                        Function type: validator
check.groupname                              Function type: validator
check.imapmailboxpath                        Function type: validator
check.int                                    Function type: validator
check.ip                                     Function type: validator
check.iprange                                Function type: validator
check.iptablescomment                        Function type: validator
check.mask                                   Function type: validator
check.money                                  Function type: validator
check.net                                    Function type: validator
check.netmask                                Function type: validator
check.password                               Function type: validator
check.path                                   Function type: validator
check.phpbadsymbol                           Function type: validator
check.relativepath                           Function type: validator
check.smtpuser                               Function type: validator
check.srv_record_target                      Function type: validator
check.staticext                              Function type: validator
check.subdomain                              Function type: validator
check.totp_token                             Function type: validator
check.url                                    Function type: validator
check.username                               Function type: validator
check.xml                                    Function type: validator
checkddos                                    Description is not available
checkdsrecords                               Description is not available
chlevel                                      Description is not available
collapse                                     Description is not available
colwidth                                     Description is not available
community                                    Function type: none
confirm                                      Function type: form
convert                                      Description is not available
coregeoipdownload                            Description is not available
dashboard                                    Home. Function type: dashboard
dashboard.limit                              Limits. Function type: list
dashboard.limit.delete                       Function type: group operation
dashboard.limit.edit                         Function type: form
dashboard.phpmyadmin                         Description is not available
dashboard.phppgadmin                         Description is not available
dashboard.roundcube                          Description is not available
dashboard.save                               Description is not available
dashboard.settings                           Settings. Function type: form
dashboard.softaculous                        Description is not available
dashboard.software                           Server software. Function type: list
dashboard.software.delete                    Function type: group operation
dashboard.software.edit                      Function type: form
dashboard.sysinfo                            System information. Function type: list
dashboard.sysinfo.delete                     Function type: group operation
dashboard.sysinfo.edit                       Function type: form
datapass                                     Change owner tasks. Function type: list
datapass.actions                             Transferred data. Details. Change owner
                                             processes. Function type: list
datapass.cancel                              Cancel. Cancel data transfer. Function type:
                                             group operation
datapass.checktry                            Description is not available
datapass.filter                              Filter of data transfer between users tasks.
                                             Filter. You can specify selection criteria for
                                             this list. They will be applied every time the
                                             list is displayed until the filter is removed
                                             or modified . Function type: form
datapass.finalize                            Description is not available
datapass.longresult                          Description is not available
datapass.newtry                              Description is not available
datapass.periodic                            Description is not available
datapass.proceed                             Description is not available
datapass.queue.push                          Description is not available
db                                           Databases . Function type: list
db.delete                                    Delete. Delete database. Function type: group
                                             operation
db.dump                                      Export . Download a dump of the selected
                                             database.
db.dumppath                                  Description is not available
db.edit                                      Database. Create a database. Create a new
                                             database. Function type: form
db.filter                                    Database filter . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
db.happyfilter                               Filter by user. Filter by owner
db.localupload                               Restore from the local database dump . Function
                                             type: form
db.params                                    Description is not available
db.restore                                   Description is not available
db.server                                    Database servers. Function type: list
db.server.dbunassigned                       Unassigned databases . Unassigned databases.
                                             List of databases that do not belong to any
                                             user. Function type: list
db.server.dbunassigned.delete                Delete. Delete database. Function type: group
                                             operation
db.server.dbunassigned.edit                  Function type: form
db.server.default.mysql                      Description is not available
db.server.delete                             Delete. Delete database server. Function type:
                                             group operation
db.server.edit                               Database server. Create a server. Create a new
                                             database server. Function type: form
db.server.filter                             Filter the list of databases . Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
db.server.get_max_username                   Description is not available
db.server.redirect                           Description is not available
db.server.settings                           Database server configuration . Settings.
                                             Database server settings. Function type: list
db.server.settings.delete                    Function type: group operation
db.server.settings.edit                      Database server parameter . Edit. Change DB
                                             server parameters. Function type: form
db.server.update_version                     Description is not available
db.size                                      Description is not available
db.su                                        Log in as user. Log in as owner
db.table.engine                              Description is not available
db.upload                                    Upload database dump. Import. Upload the
                                             database dump . Function type: form
db.users                                     Database users. Users. Change the database user
                                             settings of the selected database.. Function
                                             type: list
db.users.delete                              Delete. Delete database user. Function type:
                                             group operation
db.users.edit                                Database user. Add user. Add user. Function
                                             type: form
db.users.identity                            Description is not available
db.users.redirect                            Database web interface. Login to PhpMyAdmin
                                             with the user permissions. The database user
                                             must have a password set
defaultadmin                                 Description is not available
deletearchivelogs                            Description is not available
desktop                                      Description is not available
dhparam.finish                               Description is not available
diskusage                                    Disk usage. Function type: list
diskusage.file                               Directory. Open the selected folder in the file
                                             manager.. Function type: external function
diskusage.info                               Disk usage. Open an overview about the total
                                             amount of disk space that is used by this
                                             account.. Function type: form
dismiss                                      Description is not available
dns.blacklist                                Forbidden domains management. Function type:
                                             list
dns.blacklist.delete                         Delete. Delete domain name. Function type:
                                             group operation
dns.blacklist.edit                           Rename. Add domain. Add domain. Function type:
                                             form
dns_default_view                             Default view settings. Function type: form
dnsconfigure.dropall                         Description is not available
dnsparam                                     Domain creation settings. Function type: form
dnsparam.fixall                              Description is not available
dnssec.backup.get                            Description is not available
dnssec.backup.resign                         Description is not available
dnssec.backup.set                            Description is not available
dnssec.banner.add                            Description is not available
dnssec.banner.delete                         Description is not available
dnssec.domain                                Function type: list
dnssec.domain.change                         Description is not available
dnssec.domain.delete                         Function type: group operation
dnssec.domain.edit                           Function type: form
dnssec.domain.filter                         Function type: form
dnssec.domain.update                         Description is not available
dnssec.key                                   Function type: list
dnssec.key.change                            Description is not available
dnssec.key.delete                            Function type: group operation
dnssec.key.delete.all                        Description is not available
dnssec.key.edit                              Function type: form
dnssec.key.filter                            Function type: form
dnssec.notify                                Description is not available
dnssec.record                                Function type: list
dnssec.record.delete                         Function type: group operation
dnssec.record.edit                           Function type: form
dnssec.rollback                              Description is not available
dnssec.rollover                              Description is not available
docker.install                               Function type: form
docker.pkginstall                            Description is not available
docker.update.start                          Description is not available
domain                                       DNS management. Function type: list
domain.autorecords                           Description is not available
domain.delete                                Function type: group operation
domain.delete.request                        Confirm you want to delete domain names.
                                             Function type: form
domain.dnssecinfo                            DNSSEC parameters. DNSSEC. View DNSSEC
                                             parameters. Function type: form
domain.dump                                  Description is not available
domain.edit                                  Domain name properties. Create a DNS domain.
                                             Create a new DNS domain. Function type: form
domain.filter                                DNS filter . Filter. You can specify selection
                                             criteria for this list. They will be applied
                                             every time the list is displayed until the
                                             filter is removed or modified . Function type:
                                             form
domain.happyfilter                           Filter by user. Filter by owner
domain.passredirect                          Change owner. Transfer the domain name to
                                             another user
domain.record                                DNS record types. DNS records. Manage DNS
                                             records. Function type: list
domain.record.delete                         Delete. Delete the selected DNS record..
                                             Function type: group operation
domain.record.edit                           Domain record. Create record. Add a new DNS
                                             record.. Function type: form
domain.refresh                               Function type: group operation
domain.slaveserver                           Slave servers. Connect DNSmanager as a slave
                                             name server
domain.su                                    Log in as user . Log in with user rights
dovecot.certs.check                          Description is not available
dovecot.reload                               Description is not available
editmsg                                      Description is not available
email                                        Mail. Function type: list
email.alias                                  Aliases. Function type: list
email.alias.delete                           Delete. Delete alias. Function type: group
                                             operation
email.alias.edit                             Alias. Create alias. Create alias. Function
                                             type: form
email.alias.filter                           Aliases. Filter. You can specify selection
                                             criteria for this list. They will be applied
                                             every time the list is displayed until the
                                             filter is removed or modified . Function type:
                                             form
email.alias.redirect                         Description is not available
email.blacklist                              Blacklist. List of restricted email senders
email.check.ssl.feature                      Description is not available
email.clear                                  Clear. Clear the contents of the mailbox .
                                             Function type: group operation
email.clear.request                          Confirm that you want to purge the mailbox .
                                             Function type: form
email.delete                                 Delete. Delete mailbox. Function type: group
                                             operation
email.edit                                   Mailbox. Create mailbox. Create a new mailbox.
                                             Function type: form
email.emaildnsbl                             DNSBL. Lists of domains that are used to fight
                                             spam
email.emaildomain                            Description is not available
email.filter                                 Mailbox filter . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
email.greylist                               Description is not available
email.happyfilter                            Filter by user
email.import                                 Mailbox Import. Import. Import mailboxes from
                                             external mail server. Function type: form
email.import.report                          Mailbox import log. Function type: form
email.import.setstatus                       Description is not available
email.responder                              Autoresponder. Autoresponder settings. Set up
                                             an auto-responder. Function type: form
email.resume                                 Enable. Enable mailbox. Function type: group
                                             operation
email.setting                                Mail settings. Mail client settings. Email
                                             client preferences (Outlook, Thunderbird,
                                             etc.). Function type: form
email.setting.download                       Description is not available
email.sorter                                 Email filtering . Filter settings. Email filter
                                             settings . Function type: list
email.sorter.action                          Filter action. Actions. List of actions for the
                                             filter. Function type: list
email.sorter.action.add                      Add a new action. Function type: form
email.sorter.action.delete                   Delete. Delete action. Function type: group
                                             operation
email.sorter.action.edit                     Actions. Create action. Create action for the
                                             mail filter. Function type: form
email.sorter.add                             Email filtering. Function type: form
email.sorter.cond                            Email filter conditions. Filter rules. List of
                                             filter rules. Function type: list
email.sorter.cond.add                        Add a new filter rule. Function type: form
email.sorter.cond.delete                     Delete. Delete rule. Function type: group
                                             operation
email.sorter.cond.edit                       Filter rule. Add rule. Add mail filter rule.
                                             Function type: form
email.sorter.delete                          Delete. Delete filter. Function type: group
                                             operation
email.sorter.edit                            Email filtering. Edit. Change filter
                                             parameters. Function type: form
email.sorter.resume                          Enable. Disable filter. Function type: group
                                             operation
email.sorter.suspend                         Disable. Enable filter. Function type: group
                                             operation
email.su                                     Log in as user. Log in with user rights
email.suspend                                Disable. Disable mailbox. Function type: group
                                             operation
email.toplevel.ssl.edit                      SSL key . Function type: form
email.web                                    Mail client. Webmail client
email.whitelist                              Whitelist. List of allowed mail senders
emaildnsbl                                   List of DNSBL domains. Function type: list
emaildnsbl.delete                            Delete domain. Delete domain. Function type:
                                             group operation
emaildnsbl.edit                              Editing domain name of the DNSBL list. Create
                                             domain. Create domain. Function type: form
emaildomain                                  Mail domains. Function type: list
emaildomain.delete                           Delete. Delete email domain. Function type:
                                             group operation
emaildomain.edit                             Mail domain. Create a mail domain. Create mail
                                             domain. Function type: form
emaildomain.filter                           Mail domains filter . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
emaildomain.getsize                          Description is not available
emaildomain.happyfilter                      Filter by user. Filter by owner
emaildomain.passredirect                     Change owner. Transfer mail domain to another
                                             user
emaildomain.restore_mx                       Function type: form
emaildomain.resume                           Enable. Enable mail domain. Function type:
                                             group operation
emaildomain.su                               Log in as user. Log in as owner
emaildomain.suspend                          Disable. Disable mail domain. Function type:
                                             group operation
emailnotify                                  Notifications . Function type: form
error                                        Description is not available
errorjournal                                 Error log. Function type: list
errorjournal.delete                          Delete. Delete the selected reports. Function
                                             type: group operation
errorjournal.edit                            Error information . Send. View detailed
                                             information about the error. Send the report to
                                             developers. . Function type: form
errorjournal.filter                          Error log filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
errorjournal.settings                        Logging settings. Settings. Logging settings.
                                             Function type: list
errorjournal.settings.default                Set to default. Restore default logging
                                             settings. The logging level is reset to the
                                             value corresponding with the "All modules" list
                                             item. Function type: group operation
errorjournal.settings.delete                 Function type: group operation
errorjournal.settings.edit                   Logging settings . Edit. Change logging level
                                             for module. Function type: form
errorjournal.settings.setmax                 Maximum . Set the maximum logging settings for
                                             the selected module . Function type: group
                                             operation
eula                                         Description is not available
eventlist                                    Description is not available
exim.reload                                  Description is not available
exit                                         Description is not available
externalsslconf                              Description is not available
externalsslconf.regenmain                    Description is not available
fail2ban.jails                               Service rules. Function type: list
fail2ban.jails.delete                        Function type: group operation
fail2ban.jails.edit                          Rule settings. Edit. Change rule settings.
                                             Function type: form
fail2ban.jails.resume                        Enable. Enable the rule. Function type: group
                                             operation
fail2ban.jails.suspend                       Disable. Disable the rule. Function type: group
                                             operation
fail2ban.restart                             Description is not available
fail2ban.service.resume                      Function type: group operation
fail2ban.service.suspend                     Function type: group operation
fail2ban.settings                            Fail2ban global settings. Function type: form
feature                                      Software configuration. Function type: list
feature.check                                Description is not available
feature.delete                               Function type: group operation
feature.edit                                 Software configuration. Software settings.
                                             Software settings. Function type: form
feature.resume                               Install. Install software
feature.send                                 Description is not available
feature.suspend                              Uninstall software. Uninstall software
feature.update                               Update. Update the list of available software
                                             and OS packages. Function type: form
featurelist                                  Description is not available
featurelist.has                              Description is not available
file                                         File manager . Function type: list
file.authinfo                                Description is not available
file.avcheck                                 Function type: form
file.avcheckparams                           Virus scan. Anti-virus. Scan the selected file
                                             or directory for viruses.. Function type: form
file.avreport                                Virus scanning report. Function type: list
file.avreport.delete                         Delete. Delete the selected file or directory..
                                             Function type: external function
file.avreport.dismiss                        Function type: external function
file.avreport.edit                           Antivirus scanning report. Details. View the
                                             antivirus scan report. Function type: form
file.avreport.stop                           Stop. Stop antivirus scanning process. Function
                                             type: external function
file.copyto                                  Copy. Copy. Copy or move the selected file or
                                             directory.. Function type: form
file.delete                                  Delete. Delete the selected file or directory..
                                             Function type: external function
file.diraccess                               Protecting directory. Access. Password protect
                                             the WWW-domain's directories. Function type:
                                             form
file.download                                Download. Download the selected file(s)..
                                             Function type: external function
file.edit                                    Edit file. Open file. Open file. Function type:
                                             form
file.extract                                 Extract archive(s). Extract. Extract the
                                             selected archive.. Function type: form
file.favorites                               Description is not available
file.folder                                  Go to directory. Catalog tree. This button will
                                             open an overview of all files and folders that
                                             are stored on this account. Afterwards you can
                                             select a folder and view the content of that
                                             folder.. Function type: form
file.new                                     Create file or directory. Add. Create file or
                                             directory. Function type: form
file.open                                    Open file/catalog. Function type: external
                                             function
file.pack                                    Archive. Create. Create an archive of the
                                             selected files.. Function type: form
file.search                                  Search. Search for files and folders.. Function
                                             type: form
file.settings                                Settings. This button will open a form tha can
                                             be used to change the settings of the file
                                             manager.. Function type: form
file.space                                   Description is not available
file.unixattr                                Attributes. Name and attributes. Change the
                                             name or other settings of the selected file or
                                             directory.. Function type: form
file.upload                                  Upload . Upload a file to the selected
                                             directory. . Function type: form
file.winattr                                 Function type: external function
firewall                                     Firewall rules settings. Function type: list
firewall.countries                           List of countries . Country blocking. Block
                                             access of users from specific countries.
                                             Function type: list
firewall.countries.delete                    Function type: group operation
firewall.countries.edit                      Function type: form
firewall.countries.resume                    Block. Block all IP addresses assigned to the
                                             country . Function type: group operation
firewall.countries.rewriterules              Description is not available
firewall.countries.settings                  Settings. Settings. Block by country settings.
                                             Function type: form
firewall.countries.suspend                   Unblock. Unlock all IP addresses assigned to
                                             the country. Function type: group operation
firewall.delete                              Delete. Delete the rule along with any
                                             dependent rules. Function type: group operation
firewall.edit                                Edit the selected rule. Create rule. Create
                                             rule. Function type: form
firewall.ipset.edit                          Description is not available
fpm.autostart.fix                            Description is not available
free_space_notify                            Description is not available
ftp.reconfigure                              Description is not available
ftp.user                                     FTP users. Function type: list
ftp.user.delete                              Delete. Delete FTP user. Function type: group
                                             operation
ftp.user.edit                                FTP user. Add an FTP user. Create an FTP user.
                                             Function type: form
ftp.user.filter                              FTP user filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
ftp.user.happyfilter                         Filter by user. Filter by owner
ftp.user.resume                              Enable. Enable FTP user. Function type: group
                                             operation
ftp.user.settings                            FTP-client settings . FTP client settings.
                                             FTP-user settings . Function type: form
ftp.user.settings.download                   Description is not available
ftp.user.su                                  Log in as user. Log in as owner
ftp.user.suspend                             Disable. Disable FTP user. Function type: group
                                             operation
gdpr_docs                                    Terms of use. Function type: list
gdpr_docs.delete                             Function type: group operation
gdpr_docs.edit                               Terms of use . Create rule. Create rule.
                                             Function type: form
gdpr_docs.filter                             Terms of use . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
gdpr_docs.history                            History . View the history . Function type:
                                             list
gdpr_docs.resume                             Enable. Enable rule. Function type: group
                                             operation
gdpr_docs.suspend                            Disable. Disable rule. Function type: group
                                             operation
gdpr_export_csv                              CSV export request . Function type: form
gdpr_journal                                 Action log. Function type: list
gdpr_journal.delete                          Function type: group operation
gdpr_journal.edit                            Function type: form
gdpr_journal.filter                          Action log. Filter. You can specify selection
                                             criteria for this list. They will be applied
                                             every time the list is displayed until the
                                             filter is removed or modified . Function type:
                                             form
gdpr_remove_personaldata                     Delete my personal data. Function type: form
gdpr_restrict_personaldata                   Restrict the use of my private data . Function
                                             type: form
gdpr_termsofuse                              Terms of use . Function type: form
gdpr_termsofuse.change                       Change decision . Function type: form
gdpr_view_doc                                Description is not available
geoip_consume                                Description is not available
geoip_loader                                 Description is not available
get_dbuser_passwd                            Description is not available
globalindex                                  Description is not available
globalindex.info                             Description is not available
gonotify.post                                Description is not available
groupedit                                    Function type: form
guide.complete                               Description is not available
help                                         Description is not available
helpboard                                    Help . Function type: helpboard
helpcenter                                   Description is not available
ihttpd                                       Control panel address. Function type: list
ihttpd.certs                                 Certificates for address . Certificates . List
                                             of certificates used. If your server doesn't
                                             support SNI, you can use different certificates
                                             for different domains . Function type: list
ihttpd.certs.delete                          Delete. Delete certificate. Function type:
                                             group operation
ihttpd.certs.edit                            Certificate for domains . Add certificate. Add
                                             new certificate . Function type: form
ihttpd.delete                                Delete. Delete address. Function type: group
                                             operation
ihttpd.edit                                  Address. Add address. Add new address. Function
                                             type: form
injection                                    Description is not available
internal.aps.catalog                         Function type: list
internal.aps.catalog.delete                  Function type: group operation
internal.aps.catalog.edit                    Function type: form
internal.aps.catalog.filter                  Function type: form
internal.aps.user_catalog                    Web scripts. Function type: form
ip2location_consume                          Description is not available
ip2location_loader                           Description is not available
ipaddrlist                                   IP addresses. Function type: list
ipaddrlist.delete                            Delete. Delete the selected IP addresses .
                                             Function type: group operation
ipaddrlist.edit                              IP address. Create. Add a new IP address.
                                             Function type: form
ipaddrlist.setdefault                        default IP. The IP address is used by default
                                             when the site is created.
ipdb                                         IP address pools. Function type: list
ipdb.addr                                    IP addresses. IP addresses. IP addresses in the
                                             pool. Function type: list
ipdb.addr.delete                             Delete. Delete IP address. Function type: group
                                             operation
ipdb.addr.edit                               IP address. Add. Add IP address. Function type:
                                             form
ipdb.delete                                  Delete. Delete pool. Function type: group
                                             operation
ipdb.edit                                    Pool parameters. Add. New pool of IP addresses.
                                             Function type: form
ipdb.filter                                  Filter. You can specify selection criteria for
                                             this list. They will be applied every time the
                                             list is displayed until the filter is removed
                                             or modified . Function type: form
ipdb.firstrun                                Allocate IP addresses from. Function type: form
ipdb.settings                                Special domain names. Domain of special
                                             addresses. Special address domain
                                             configuration. Function type: form
ipdb_freeip                                  Description is not available
ipdb_set_gateway                             Range gateway. Function type: form
ipmanagement.info                            Description is not available
ipmgr                                        Integration with IPmanager . Function type:
                                             form
ipmgr2.can_v2                                Description is not available
ipmgr2.setoption                             Description is not available
ipparam                                      Description is not available
ispdns_slave                                 Description is not available
ispstat                                      Description is not available
journal                                      Action log. Function type: list
journal.delete                               Function type: group operation
journal.edit                                 Action log . Details. Transaction info.
                                             Function type: form
journal.filter                               Log filter. Filter. Set filter . Function type:
                                             form
journal.stat                                 Function usage over period. Report. Report on
                                             feature usage statistics for different time
                                             periods. Function type: report
keepalive                                    Description is not available
letsencrypt.backup.get                       Description is not available
letsencrypt.backup.set                       Description is not available
letsencrypt.check.update                     Description is not available
letsencrypt.data                             Function type: list
letsencrypt.data.delete                      Function type: group operation
letsencrypt.data.edit                        Function type: form
letsencrypt.generate                         Let’s Encrypt. Function type: form
letsencrypt.logs                             Event log. Function type: list
letsencrypt.logs.full                        Full log
letsencrypt.logs.last                        Log of the last attempt
letsencrypt.logs.run                         Resume. Resume the procedure of the Let's
                                             Encrypt certificate issue
letsencrypt.logs.write                       Description is not available
letsencrypt.periodic                         Description is not available
letsencrypt.txt                              Let's Encrypt TXT records. Function type: form
letsencrypt_challenge                        Description is not available
letsencrypt_setaliases                       Description is not available
license                                      Activate license. Function type: form
license.download                             Description is not available
license.fetch.task                           Description is not available
license.info                                 About program. Function type: form
license.mgr.info                             About __panel_name__
license.register                             License registration. Function type: form
license.upload                               Description is not available
license.webdomain.info                       Description is not available
load_dns_zone                                Description is not available
logon                                        Description is not available
longtask                                     Background tasks. Function type: list
longtask.delete                              Stop . Stop the task. If the job is already
                                             running, the job will be interrupted. Function
                                             type: group operation
longtask.edit                                Background task . View. View the detailed task
                                             info. Function type: form
longtask.filter                              Background task. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
mail.settings                                Mail settings. Function type: form
mailrate.default                             Email limit settings. Function type: form
menu                                         Description is not available
menuvisited                                  Description is not available
metadatabyaction                             Description is not available
modulesfailed                                Function type: list
modulesloaded                                Function type: list
monitoring.add                               Monitoring system settings. Function type: form
monitoring.remove                            Function type: group operation
monitoring.settings                          Monitoring system settings. Function type: form
mysqlcheck.check                             Description is not available
mysqlcheck.repair                            Description is not available
mysqlcheck.repair.table                      Description is not available
mysqlcheck.report                            mysqlcheck report. Function type: list
mysqlcheck.report.delete                     Function type: group operation
mysqlcheck.report.edit                       Function type: form
mysqlcheck.result                            Description is not available
nat.settings                                 NAT settings . Function type: form
navboard                                     Navigation board
nestedlist                                   Description is not available
netactconn                                   Active network connections . Function type:
                                             list
netactconn.detail                            Active network connections . Details. Full list
                                             of currently active connections. Function type:
                                             list
netactconn.detail.adddenyip                  Block IP address. Deny access to the server
                                             from the selected IP addresses
netactconn.detail.showbycountry              Connections per country. By countries .
                                             Connections by country. Function type: list
netactconn.detail.showbysubnet               Connections per subnet . By subnets .
                                             Connections by network. Function type: list
netactconn.detail.showbysubnet.adddenysubnet Edit the selected rule. Block. Block subnet.
                                             Function type: form
netsrv                                       Network services. Function type: list
netsrv.delete                                Function type: group operation
netsrv.edit                                  Add rule. Add rule. Add a firewall rule for the
                                             selected service. Function type: form
nginx.http2.final                            Description is not available
nginx.http2.queue                            Description is not available
nginx.pagespeed.configure                    Description is not available
nginx.pagespeed.deconfigure                  Description is not available
nginx.restart                                Description is not available
nginx.ssl_fix                                Description is not available
nolicense.license                            License management. Function type: form
nolicense.license.activate                   Activate license. Function type: form
nolicense.license.buy                        Choose tariff. Function type: form
nolicense.license.change                     Choose tariff. Function type: form
nolicense.license.isp5                       You are now using ispmanager 5 license.
                                             Function type: form
nolicense.license.prolong                    License renewal. Function type: form
notice.confirm                               Email Confirmation
notify                                       Description is not available
notify.send                                  Description is not available
notloaded                                    Description is not available
notloaded.show                               The module is not uploaded . Function type:
                                             form
oauth                                        Description is not available
oauth.redirect                               Description is not available
optionlist                                   Function type: list
optionlist.delete                            Function type: group operation
optionlist.edit                              Function type: form
panel.update                                 Description is not available
panelsettings                                Panel settings. Function type: form
paramlist                                    Function type: list
paramlist.delete                             Function type: group operation
paramlist.edit                               Function type: form
passdb                                       Database owner change. Function type: form
passdomain                                   Transfer data to another user. Function type:
                                             form
pathlist                                     Function type: list
pathlist.delete                              Function type: group operation
pathlist.edit                                Function type: form
periodic                                     Description is not available
perlext                                      Perl extensions. Function type: list
perlext.delete                               Function type: group operation
perlext.edit                                 Function type: form
perlext.filter                               Perl extensions filter . Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
perlext.install                              Install. Install extension
perlext.uninstall                            Delete. Delete extension
phoenix.rate                                 Description is not available
phpconf                                      Advanced PHP settings. Function type: list
phpconf.default                              Reset settings. Restore the default variable
                                             value. Function type: group operation
phpconf.delete                               Function type: group operation
phpconf.edit                                 Edit variable. Edit. Edit the selected
                                             variable. Function type: form
phpconf.filter                               PHP parameter filter. Filter. Filter. Function
                                             type: form
phpconf.mainsettings                         Description is not available
phpconf.phpcomposer                          PHP Composer. Go to the PHP Composer section
                                             for the selected site
phpconf.resume                               Show. Show the variable in the list of user
                                             settings. Function type: group operation
phpconf.set_param                            Description is not available
phpconf.setavail                             Description is not available
phpconf.settings                             Initial PHP configuration. Main settings. Main
                                             settings for the selected PHP version. Function
                                             type: form
phpconf.suspend                              Hide. Hide the variable from user settings
                                             list. Function type: group operation
phpextensions                                PHP extensions. Function type: list
phpextensions.delete                         Function type: group operation
phpextensions.edit                           Function type: form
phpextensions.install                        Install. Install extension. Function type:
                                             group operation
phpextensions.resume                         Enable. Enable the selected extension. Function
                                             type: group operation
phpextensions.suspend                        Disable. Disable the selected extension.
                                             Function type: group operation
phpextensions.uninstall                      Uninstall. Uninstall extension. Function type:
                                             group operation
phpsec.dump                                  Description is not available
phpsec.restore                               Description is not available
phpsechomefix                                Description is not available
phpversions                                  PHP. Function type: list
phpversions.install                          Install. Install the selected PHP version.
                                             Function type: group operation
phpversions.uninstall                        Uninstall. Uninstall the selected PHP version.
                                             Function type: group operation
plugin                                       Modules. Function type: form
plugin.afterinstall                          Description is not available
plugin.buy                                   Buy a plug-in
plugin.pbuy                                  Buy a plug-in. Function type: form
plugin.setinitialized                        Description is not available
plugin.settings                              Description is not available
plugin.uninstall                             Description is not available
preset                                       User templates. Function type: list
preset.delete                                Delete. Delete template. Function type: group
                                             operation
preset.edit                                  Template. Create template. Create template.
                                             Function type: form
preset.edit.redirect.reseller                Description is not available
preset.edit.redirect.user                    Description is not available
preset.filter                                Templates filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
problems                                     Notifications. Function type: list
problems.autosolve                           Description is not available
problems.clone                               Description is not available
problems.delete                              Delete. Delete the selected error message..
                                             Function type: group operation
problems.edit                                Notification. Details . Open notification
                                             characteristics. Function type: form
problems.filter                              Notifications filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
problems.log                                 Log . Log. Notification sequence log. Function
                                             type: list
problems.register                            Description is not available
problems.settings                            Notification module settings. Settings.
                                             Configure notifications. Function type: form
problems.solve                               Fix. Run an automatic fix for the problem.
                                             Function type: group operation
progress.get                                 Description is not available
progress.set                                 Description is not available
publicip                                     Description is not available
pythonext                                    Python extensions. Function type: list
pythonext.delete                             Function type: group operation
pythonext.edit                               Function type: form
pythonext.filter                             Python extensions filter . Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
pythonext.install                            Install. Install extension
pythonext.uninstall                          Delete. Delete extension
reboot                                       Description is not available
reboot_confirm                               Server reboot. Function type: form
recache.email                                Description is not available
recache.email.alias                          Description is not available
recache.email.dkim                           Description is not available
recache.email.dmarc                          Description is not available
recache.webdomain                            Description is not available
recovery                                     Password recovery. Function type: form
recovery.change                              Password recovery. Function type: form
recovery.post                                Password recovery. Function type: form
relogin                                      Description is not available
remote_dns_check                             Description is not available
reports                                      Report list. Function type: list
reports.delete                               Function type: group operation
reports.edit                                 Function type: form
reports.run                                  Generate. Generate report
request                                      Active requests . Function type: list
request.filter                               Active requests filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
request.finish                               Stop. Terminate the selected requests. They
                                             will be marked as Terminating. It will be shown
                                             when accessing the library functions. The
                                             request will be terminated after that call. A
                                             user will be notified that his request was
                                             terminated.. Function type: group operation
resellerstat                                 Limits. Function type: list
resellerstat.delete                          Function type: group operation
resellerstat.details                         Resource information. Details. Detailed
                                             information related to the selected resource
                                             type. Function type: list
resellerstat.details.delete                  Function type: group operation
resellerstat.details.edit                    Function type: form
resellerstat.edit                            Function type: form
resource_monitoring                          Resource monitoring. Function type: form
restore.admin                                Description is not available
restore.admindomain                          Description is not available
restore.aps                                  Description is not available
restore.db                                   Description is not available
restore.db.users                             Description is not available
restore.domain                               Description is not available
restore.email                                Description is not available
restore.emaildomain                          Description is not available
restore.ftp.user                             Description is not available
restore.preset                               Description is not available
restore.scheduler                            Description is not available
restore.sslcert                              Description is not available
restore.sslcsr                               Description is not available
restore.user                                 Description is not available
restore.userconf                             Description is not available
restore.webdomain                            Description is not available
restore.webdomain.diraccess                  Description is not available
restore.webdomain.diraccess.user             Description is not available
restore.webdomain.error                      Description is not available
restore.webdomain.redirect                   Description is not available
run                                          Execute command. Function type: form
scheduler                                    Scheduler. Function type: list
scheduler.delete                             Delete. Delete task. Function type: group
                                             operation
scheduler.edit                               Crob job. Create plan. Create a task. Function
                                             type: form
scheduler.prop                               Settings. Global cronjob settings.. Function
                                             type: form
scheduler.resume                             Enable. Enable task. Function type: group
                                             operation
scheduler.suspend                            Disable . Disable task. Function type: group
                                             operation
send.update.notify                           Description is not available
server_capacity                              Server resources . Function type: report
services                                     Services. Function type: list
services.addmon                              Description is not available
services.delete                              Function type: group operation
services.deletemon                           Description is not available
services.disable                             Autostart OFF. Disable autostart for this
                                             service. Function type: group operation
services.edit                                Function type: form
services.enable                              Autostart ON. Enable autostart for this
                                             service. Function type: group operation
services.exclude                             Show. Add to Services list
services.filter                              Services filter . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
services.notresponse.problem                 The service does not respond
services.restart                             Restart. Restart the selected service. Function
                                             type: group operation
services.restart.problem                     Restart the service
services.resume                              Start. Start the selected service. Function
                                             type: group operation
services.setbin                              Enter the name for the service process . Edit.
                                             Specify a binary file for the service for
                                             monitoring status. Function type: form
services.stop.problem                        Service not running
services.suspend                             Stop. Stop the selected service. Function type:
                                             group operation
services.unknown                             All services. List of services which current
                                             status was not defined
session                                      Active sessions. Function type: list
session.delete                               Stop. Terminate session. To continue working in
                                             the control panel the user must go through the
                                             authorization process.. Function type: group
                                             operation
session.edit                                 Function type: form
session.filter                               Sessions filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
session.newkey                               Description is not available
session.su                                   Log in. Log in to the control panel with the
                                             same access privileges
setapache                                    Description is not available
settings.auth                                Authorization settings. Function type: form
setuserfpm                                   Description is not available
shell                                        Shell-client . Function type: form
site.backup.get                              Description is not available
site.backup.info                             Description is not available
site.backup.set                              Description is not available
site.clone                                   Website cloning. Function type: form
site.db.redirect                             Description is not available
site.edit                                    Website. Function type: form
sitepro.autoinstall                          Install Site.pro. Function type: form
slaveserver                                  Slave name servers. Function type: list
slaveserver.byns                             Function type: list
slaveserver.delete                           Delete. Delete the selected slave name servers.
                                             Function type: group operation
slaveserver.domainbyns                       Function type: list
slaveserver.edit                             Slave name server. Add server. Add a new slave
                                             name server. Function type: form
slaveserver.fix                              Function type: group operation
spamexperts.emaildomain.processmx            Description is not available
srvparam                                     System settings. Function type: form
sslcert                                      SSL certificates . Function type: list
sslcert.add                                  Description is not available
sslcert.csr                                  Certificate Signing Request (CSR) . CSR. Create
                                             a new SSL CSR.. Function type: list
sslcert.csr.approve                          Approve CSR . Confirm . Generate an SSL
                                             certificate based on CSR and delete the CSR
                                             after the SSL certificate has been generated..
                                             Function type: form
sslcert.csr.delete                           Delete. Delete the selected CSR.. Function
                                             type: group operation
sslcert.csr.dump                             Description is not available
sslcert.csr.edit                             CSR. Create request. Generate a new CSR..
                                             Function type: form
sslcert.csr.filter                           CSR filter . Filter. You can specify selection
                                             criteria for this list. They will be applied
                                             every time the list is displayed until the
                                             filter is removed or modified . Function type:
                                             form
sslcert.csr.happyfilter                      Filter by user
sslcert.csr.restore                          Description is not available
sslcert.delete                               Delete. Delete the selected SSL certificate..
                                             Function type: group operation
sslcert.domain.getlist                       Description is not available
sslcert.dump                                 Description is not available
sslcert.edit                                 Information . Certificate data. SSL certificate
                                             information. Function type: form
sslcert.filter                               SSL-certificates filter. Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
sslcert.happyfilter                          Filter by user. Filter by owner
sslcert.hardreplace                          Description is not available
sslcert.prolong                              Renew SSL certificate . Renew . Renew the
                                             selected SSL certificate without changing the
                                             certificate key.. Function type: form
sslcert.replace                              Change the SSL certificate. Change. Change the
                                             selected SSL certificate. This option can be
                                             used to assign a different SSL certificate to a
                                             domain. . Function type: form
sslcert.selfsigned                           Create an SSL certificate. Self-signed .
                                             Generate a self-signed SSL certificate.
                                             Function type: form
sslcert.setcrt                               Create an SSL certificate. Existing . Add an
                                             SSL certificate issued by a certificate
                                             authority or by yourself. Function type: form
sslcert.su                                   Log in as user . Log in as owner
su                                           Description is not available
support.key.check                            Description is not available
sysinfo                                      System information . Function type: list
sysinfo.cpu                                  CPU usage. CPU usage. Function type: list
sysinfo.disk                                 Disk information . Disk information. Function
                                             type: list
sysinfo.proc                                 List of processes. List of processes. Function
                                             type: list
sysinfo.proc.kill                            Stop . Terminate the selected processes .
                                             Function type: group operation
sysinfo.seltype                              Details. Parameter information
sysinfostat                                  Description is not available
techdomain.dropall                           Description is not available
telegram.chat.add                            Description is not available
theme.color.change                           Theme. Function type: form
theme.update                                 Description is not available
tip                                          Description is not available
totp.confirm                                 Authorization. Function type: form
totp.new                                     Two-factor authentication . Function type: form
totp.new.file                                Description is not available
tsetting                                     Table settings . Function type: form
tsort                                        Description is not available
user                                         Users. Function type: list
user.add                                     Add a user. Create user. Function type: form
user.add.addinfo                             Additional information. Function type: form
user.add.finish                              User. Function type: form
user.add.user                                User. Function type: form
user.delete                                  Delete. Delete user. Function type: group
                                             operation
user.edit                                    User. Edit. Change user parameters. Function
                                             type: form
user.exists                                  Description is not available
user.filter                                  Filter the list of users. Filter. You can
                                             specify selection criteria for this list. They
                                             will be applied every time the list is
                                             displayed until the filter is removed or
                                             modified . Function type: form
user.happyfilter                             Filter by user. Set filter by user
user.history                                 History . View the history . Function type:
                                             list
user.preset                                  Templates. Templates allow you to create users
                                             with preset settings
user.resume                                  Enable. Enable user. Function type: group
                                             operation
user.suspend                                 Disable. Disable user. Function type: group
                                             operation
user_disk_report                             Disk usage. Function type: report
user_quota_exceeded                          Users who have exceeded their disk quota .
                                             Function type: list
userlogs                                     Site logs. Function type: list
userlogs.archive                             Log archive. Archive. Open an overview of
                                             archived log files. There you can download a
                                             previous made log files or delete them..
                                             Function type: list
userlogs.archive.delete                      Function type: group operation
userlogs.archive.download                    Description is not available
userlogs.archive.edit                        Function type: form
userlogs.archive.filter                      Function type: form
userlogs.archive.users                       Function type: list
userlogs.archive.users.filter                Function type: form
userlogs.archive.users.happyfilter           Description is not available
userlogs.delete                              Clear. Clear archive file. Function type: group
                                             operation
userlogs.download                            Download. Download archive file
userlogs.edit                                View user log. View. View the selected log
                                             file.. Function type: form
userlogs.filter                              WWW-logs filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
userlogs.users                               Site logs. Function type: list
userlogs.users.filter                        Users filter . Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
userlogs.users.happyfilter                   Description is not available
usermenu.pin                                 Description is not available
usermenu.resume                              Description is not available
usermenu.suspend                             Description is not available
usermenu.unpin                               Description is not available
usermove                                     Function type: form
usermove.apply_users_limit                   Description is not available
usermove.check                               Function type: form
usermove.check.cancel                        Description is not available
usermove.check.type                          Function type: form
usermove.confirm                             Function type: form
usermove.cpanel_remote                       Function type: form
usermove.create                              Description is not available
usermove.db.finish                           Description is not available
usermove.db.prepare                          Description is not available
usermove.finish                              Description is not available
usermove.first                               Function type: form
usermove.info                                Description is not available
usermove.ispmgr4_arc                         Function type: form
usermove.ispmgr4_remote                      Function type: form
usermove.ispmgr5_remote                      Function type: form
usermove.journal.details.add                 Description is not available
usermove.journal.set                         Description is not available
usermove.last                                Function type: form
usermove.list                                Migration tool. Function type: list
usermove.list.cancel                         Cancel import. Cancel
usermove.list.clear_param_files              Description is not available
usermove.list.delete                         Delete. Delete . Function type: group operation
usermove.list.edit                           Function type: form
usermove.list.journal                        Migration tool log. Log. Function type: list
usermove.list.journal.filter                 Migration tool log. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
usermove.panel                               Function type: form
usermove.params                              Function type: form
usermove.params.backup                       Function type: form
usermove.params.cpanel                       Function type: form
usermove.run                                 Description is not available
usermove.source                              Function type: form
usermove.source.user                         Function type: form
usermove.terminating.finish                  Description is not available
usermove2                                    Function type: form
usermove2.ispmgr4_arc                        Function type: form
usermove2.ispmgr4_remote                     Function type: form
usermove2.last                               Function type: form
userrights                                   Rights. Function type: list
userrights.delete                            Set to default. Any changes made will be lost.
                                             All access settings that have been made for the
                                             user/group will be deleted, including column
                                             and column permissions if it is a list or form.
                                             Function type: group operation
userrights.edit                              Access to functions. Permissions. Configure
                                             access rights to functions. Function type: form
userrights.fields                            List of fields (columns) . Fields and columns.
                                             Customize display of list columns and form
                                             fields. Function type: list
userrights.fields.delete                     Reset branding settings. Restore default
                                             settings. Any changes made will be lost. All
                                             access settings that have been made for the
                                             user/group will be deleted, including column
                                             and column permissions if it is a list or form.
                                             Function type: group operation
userrights.fields.edit                       Field privileges . Default settings. Default
                                             permission settings. Function type: form
userrights.fields.resume                     Enable. Enable access to column or field.
                                             Function type: group operation
userrights.fields.suspend                    Disable. Disable access to column or field.
                                             Function type: group operation
userrights.filter                            Filter. Restrict access to some of the listed
                                             data. Function type: form
userrights.group                             Functions access. Back. Back to the previous
                                             list . Function type: list
userrights.group.delete                      Delete. Delete the selected groups . Function
                                             type: group operation
userrights.group.edit                        Group. Create access group. Create access
                                             group. Function type: form
userrights.group.users                       User groups. Users. Select users. It enables to
                                             assign/unassign users from the selected group.
                                             Function type: list
userrights.group.users.delete                Function type: group operation
userrights.group.users.edit                  Function type: form
userrights.group.users.resume                Enable. Enable access to function. Function
                                             type: group operation
userrights.group.users.suspend               Disable. Disable access to the function. Access
                                             changes for all child functions as well.
                                             Function type: group operation
userrights.policy                            Policy. Policy. Customize access to functions
                                             for which restrictions are not set. Function
                                             type: form
userrights.resume                            Enable. Enable access to function. Function
                                             type: group operation
userrights.suspend                           Disable. Disable access to the function. Access
                                             changes for all child functions as well.
                                             Function type: group operation
userrights.user                              Description is not available
usershell                                    Shell-client . Function type: form
userstat                                     Limits. Function type: list
userstat.delete                              Function type: group operation
userstat.edit                                Function type: form
usrparam                                     User settings. Function type: form
usrparam.telegram                            Telegram notifications . Function type: form
version.actual                               Description is not available
video_tutorials                              Video tutorials
web.configtest.apache                        Description is not available
web.configtest.nginx                         Description is not available
webanalyzer.delete                           Description is not available
webanalyzer.edit                             Description is not available
webdav.remoteip                              Description is not available
webdomain                                    Websites. Function type: list
webdomain.aliases                            Description is not available
webdomain.backup                             Creating backup copy. Create a backup copy of
                                             the website. Function type: form
webdomain.bad                                List of websites with errors in properties.
                                             Function type: list
webdomain.config.replace                     Description is not available
webdomain.delete                             Function type: group operation
webdomain.delete.confirm                     Confirm that you want to delete the websites.
                                             Function type: form
webdomain.diraccess                          Protecting directory. Access limits. Password
                                             protect the website directories. Function type:
                                             list
webdomain.diraccess.add                      Create restriction. Create restriction.
                                             Function type: form
webdomain.diraccess.add.dir                  Select a website subdirectory. Function type:
                                             form
webdomain.diraccess.add.user                 Add a user. Function type: form
webdomain.diraccess.delete                   Delete. Delete restriction. Function type:
                                             group operation
webdomain.diraccess.edit                     Function type: form
webdomain.diraccess.filter                   Function type: form
webdomain.diraccess.repair                   Description is not available
webdomain.diraccess.user                     Users of the password protected directory.
                                             Users. Open an overview of users who have
                                             access to a password protected folder. You can
                                             also change the settings of existing users or
                                             add new users.. Function type: list
webdomain.diraccess.user.delete              Delete. Delete user. Function type: group
                                             operation
webdomain.diraccess.user.edit                User. Add user. Add user. Function type: form
webdomain.diraccess.user.filter              Function type: form
webdomain.diraccess.user.resume              Enable. Enable user. Function type: group
                                             operation
webdomain.diraccess.user.suspend             Disable. Disable user. Function type: group
                                             operation
webdomain.edit                               Website. Function type: form
webdomain.error                              Error pages . Error pages. Open an overwiew of
                                             the error pages of the selected domain or add
                                             new error pages.. Function type: list
webdomain.error.delete                       Delete. Delete page. Function type: group
                                             operation
webdomain.error.edit                         Error page. Create page. Create page. Function
                                             type: form
webdomain.file                               Site files. Open the website directory in the
                                             file manager
webdomain.file.manage                        Description is not available
webdomain.filter                             Websites filter. Filter. You can specify
                                             selection criteria for this list. They will be
                                             applied every time the list is displayed until
                                             the filter is removed or modified . Function
                                             type: form
webdomain.get_conf_values                    Description is not available
webdomain.getsize                            Description is not available
webdomain.go                                 Open website in browser. Open the selected
                                             website in a browser.
webdomain.happyfilter                        Filter by user. Filter by owner
webdomain.journal                            Log . The log of WWW-requests to the website
webdomain.letsencrypt.log                    Description is not available
webdomain.letsencrypt.txt                    Description is not available
webdomain.passredirect                       Change owner. Transfer website to another user
webdomain.plain                              Website configuration files. Configuration
                                             files. Edit site configuration files. Function
                                             type: form
webdomain.redirect                           Redirects. Redirects settings. List of
                                             redirects . Function type: list
webdomain.redirect.delete                    Delete. Delete redirect rule. Function type:
                                             group operation
webdomain.redirect.edit                      Redirect . Create redirect rule. Create
                                             redirect rule. Function type: form
webdomain.restore                            Restoring website. Restore website from a copy.
                                             Function type: form
webdomain.resume                             Enable. Enable website. Function type: group
                                             operation
webdomain.stat                               Statistics. View the website access statistics.
                                             Enter the password to access, if needed.
webdomain.su                                 Log in as owner. Log in as owner
webdomain.suspend                            Disable. Disable website. Function type: group
                                             operation
webdomain.userplain                          Website configuration files. Configuration
                                             files. Edit configuration files of the website
                                             . Function type: form
webmailredir                                 Description is not available
webproxy                                     WWW redirects. Function type: list
webproxy.check.ttl                           Description is not available
webproxy.delete                              Function type: group operation
webproxy.edit                                WWW redirect. Function type: form
webreconfigure.finalize                      Function type: group operation
webreconfigure.initialize                    Description is not available
webreconfigure.php                           Description is not available
webreconfigure.phplimits                     Description is not available
webreconfigure.restore                       Description is not available
webreconfigure.webserver                     Description is not available
webscript                                    Function type: list
webscript.delete                             Function type: group operation
webscript.edit                               Function type: form
webscript.entry                              Web scripts packages. Function type: list
webscript.entry.delete                       Function type: group operation
webscript.entry.edit                         Function type: form
webscript.entry.resume                       Allow . Allow users to install this package .
                                             Function type: group operation
webscript.entry.suspend                      Forbid. Forbid users to use this package .
                                             Function type: group operation
webscript.install                            Function type: form
webscript.install.complete                   Description is not available
webscript.install.settings                   Installation parameters . Function type: form
webscript.install.start                      Web script. Function type: form
webscripts.sync                              Description is not available
websettings                                  Web server settings. Function type: form
whitelist                                    Whitelist. Function type: list
whitelist.delete                             Delete. Delete rule. Function type: group
                                             operation
whitelist.edit                               Whitelist rule. Create rule. Add a rule to the
                                             Whitelist . Function type: form
whoami                                       Description is not available
wizard.auto                                  Insufficient data. Function type: form
wordpress                                    WordPress. Function type: list
wordpress.filter                             WordPress. Filter. You can specify selection
                                             criteria for this list. They will be applied
                                             every time the list is displayed until the
                                             filter is removed or modified . Function type:
                                             form
wordpress.info                               WordPress. Function type: form
wordpress.info.update                        Description is not available
wordpress.plugin.installed                   Description is not available
wordpress.plugin.one.resume                  Description is not available
wordpress.plugin.one.suspend                 Description is not available
wordpress.plugin.resume                      Description is not available
wordpress.plugin.suspend                     Description is not available
wordpress.site.edit                          Website settings. Function type: form
wordpress.theme                              WordPress Themes. Function type: form
wordpress.theme.installed                    Description is not available
wordpress.update                             Install updates. Install current versions of
                                             CMS, themes and plugins.
xset.up                                      Description is not available
[root@easy0388 ~]#