# Facts give each host's distribution, which picks where MariaDB keeps its
# configuration and whether SELinux needs telling about the port.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  redhat_hosts = { for name, h in var.hosts : name => h if local.family[name] == "redhat" }

  # Both families read every file in their drop-in directory in name order,
  # and the last value read wins. zz- sorts after the packages' own files,
  # such as Debian's 50-server.cnf, which sets bind-address, and Red Hat's
  # mariadb-server.cnf.
  layout = {
    debian = {
      config   = "/etc/mysql/mariadb.conf.d/zz-conn3x.cnf"
      mariadbd = "/usr/sbin/mariadbd"
    }
    redhat = {
      config   = "/etc/my.cnf.d/zz-conn3x.cnf"
      mariadbd = "/usr/libexec/mariadbd"
    }
  }
  hosts = { for name, f in local.family : name => local.layout[f] }

  port = try(var.settings.port, "3306")

  conf = join("", concat(
    ["# Managed by Conn3x.\n[mariadbd]\n"],
    [for k, val in merge(var.settings, { bind-address = var.bind_address }) : "${k} = ${val}\n"],
  ))

  password_dir = "/etc/conn3x/mariadb"

  # Each user exists once per entry in user_hosts.
  accounts = { for u in var.users : u => [for h in var.user_hosts : "'${u}'@'${h}'"] }

  # In a database-level grant, _ and % are wildcards, so app_db would also
  # match appXdb. Escaping them grants on that one database.
  grants = {
    for g in var.grants : "${g.user}:${g.database}" => merge(g, {
      db  = replace(replace(g.database, "_", "\\_"), "%", "\\%")
      all = contains(g.privileges, "ALL PRIVILEGES")
    })
  }
}

# SELinux only lets MariaDB bind ports labelled mysqld_port_t, which 3306
# already is. Another port gets the label here, on hosts where SELinux is on.
circuit "mariadb_selinux" {
  hosts = local.redhat_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "semanage" {
    for_each = local.port == "3306" ? [] : ["policycoreutils-python-utils"]
    package {
      name = item.value
    }
  }

  step "port" {
    for_each = local.port == "3306" ? [] : [local.port]
    command {
      command = "semanage port -a -t mysqld_port_t -p tcp ${item.value} || semanage port -m -t mysqld_port_t -p tcp ${item.value}"
      unless  = "! selinuxenabled || semanage port -l | awk '$1 == \"mysqld_port_t\" && $2 == \"tcp\"' | grep -qw ${item.value}"
    }
  }
}

circuit "mariadb" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Each supported release ships a MariaDB long-term release as
  # mariadb-server, so the distribution's own package, with its security
  # updates, is the one installed.
  step "server" {
    package {
      name = "mariadb-server"
    }
    depends_on = [conn3x_command.mariadb_selinux__port]
  }

  step "config" {
    file {
      path    = local.hosts[each.key].config
      content = local.conf
      mode    = "0644"
    }
  }

  # Before anything restarts, checks the new file. mariadbd reads every
  # option file as a server start would and stops at an option it doesn't
  # know, so a misspelt setting fails the apply and the running server
  # keeps what it had.
  step "check" {
    command {
      command = "cd / && out=$(${local.hosts[each.key].mariadbd} --user=mysql --help --verbose 2>&1 >/dev/null) || { echo \"$out\" >&2; exit 1; }"
      triggers = {
        config = conn3x_file.mariadb__config[each.key].revision
      }
    }
  }

  # bind-address, port and most settings only take effect on a restart. It
  # runs here rather than in a handler so the steps below find the server
  # running with the new settings. On Red Hat's first apply it's what starts
  # the server.
  step "restart" {
    command {
      command = "systemctl restart mariadb"
      triggers = {
        config = conn3x_file.mariadb__config[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "mariadb"
      state   = "started"
      enabled = true
    }
  }

  # What mysql_secure_installation does, apart from the root password: root
  # logs in over the local socket as the system's root, which is how this
  # circuit itself connects, so it has no password to set.
  step "secure" {
    command {
      command = <<-EOT
        set -e
        drops=$(mariadb -NB -e "SELECT CONCAT('DROP USER ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'))")
        printf '%s\n' "$drops" | mariadb
        mariadb <<'SQL'
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db IN ('test', 'test\_%');
        FLUSH PRIVILEGES;
        SQL
      EOT
      unless  = <<-EOT
        n=$(mariadb -NB <<'SQL'
        SELECT (SELECT COUNT(*) FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')))
             + (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'test')
             + (SELECT COUNT(*) FROM mysql.db WHERE Db IN ('test', 'test\_%'));
        SQL
        ) && [ "$n" = 0 ]
      EOT
    }
  }

  step "password_dir" {
    directory {
      path = local.password_dir
      mode = "0700"
    }
  }

  # Each password lands in a root-only file, never in state or the plan.
  step "password" {
    for_each = toset(var.users)
    file {
      path       = "${local.password_dir}/${item.key}"
      content_wo = var.user_passwords[item.key]
    }
  }

  # Creates the accounts locked, so none of them is ever open without a
  # password. set_password unlocks them.
  step "user" {
    for_each = toset(var.users)
    command {
      command = "mariadb -e \"CREATE USER IF NOT EXISTS ${join(", ", local.accounts[item.key])} ACCOUNT LOCK\""
      unless  = "[ \"$(mariadb -NB -e \"SELECT COUNT(*) FROM mysql.user WHERE User = '${item.key}' AND Host IN ('${join("', '", var.user_hosts)}')\")\" = ${length(var.user_hosts)} ]"
    }
  }

  # Sets the password when its file changed or an account was added. The
  # password reaches mariadb on stdin as part of the SQL, so it never shows
  # in ps, and the server stores only its hash.
  step "set_password" {
    for_each = toset(var.users)
    command {
      command = <<-EOT
        set -e
        pw=$(sed -e 's/\\/\\\\/g' -e "s/'/''/g" ${local.password_dir}/${item.key} | tr -d '\n')
        printf '%s\n' "ALTER USER ${join(", ", [for a in local.accounts[item.key] : "${a} IDENTIFIED BY '$pw'"])} ACCOUNT UNLOCK;" | mariadb
      EOT
      triggers = {
        password = conn3x_file.mariadb__password["${each.key}/${item.key}"].revision
        user     = conn3x_command.mariadb__user["${each.key}/${item.key}"].revision
      }
    }
  }

  step "database" {
    for_each = toset(var.databases)
    command {
      command = "mariadb -e 'CREATE DATABASE IF NOT EXISTS `${item.key}`'"
      unless  = "mariadb -NB -e \"SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${item.key}'\" | grep -qx 1"
    }
  }

  # GRANT only adds, so running it again is harmless. unless looks for every
  # privilege on every one of the user's accounts.
  step "grant" {
    for_each = local.grants
    command {
      command = <<-EOT
        mariadb <<'SQL'
        GRANT ${join(", ", item.value.privileges)} ON `${item.value.db}`.* TO ${join(", ", local.accounts[item.value.user])};
        SQL
      EOT
      unless = item.value.all ? join(" && ", [
        for a in local.accounts[item.value.user] :
        "mariadb -NBr -e \"SHOW GRANTS FOR ${a}\" | grep -qF 'GRANT ALL PRIVILEGES ON `${item.value.db}`.* TO'"
      ]) : <<-EOT
        n=$(mariadb -NB <<'SQL'
        SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES
         WHERE TABLE_SCHEMA = '${item.value.db}'
           AND GRANTEE IN (${join(", ", [for h in var.user_hosts : "'''${item.value.user}''@''${h}'''"])})
           AND PRIVILEGE_TYPE IN ('${join("', '", item.value.privileges)}');
        SQL
        ) && [ "$n" = ${length(var.user_hosts) * length(item.value.privileges)} ]
      EOT
    }
  }
}
