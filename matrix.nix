# /etc/nixos/matrix.nix
# ═══════════════════════════════════════════════════════════════════════════
# ЕДИНСТВЕННОЕ ЧТО НУЖНО МЕНЯТЬ — СЕКЦИЯ cfg = { ... }
# Деплой с нуля:
#   nixos-rebuild switch
# Всё остальное автоматически.
# ═══════════════════════════════════════════════════════════════════════════
{ config, pkgs, lib, ... }:
let
  cfg = {
    serverName       = "matrix.example.com";
    elementFqdn      = "element.example.com";
    turnFqdn         = "turn.example.com";
    adminEmail       = "MAIL FOR CERT";
    livekitNodeIp    = "PUBLIC IP OF VPS";
    livekitApiKey    = "live_kit_strong_api";
    livekitApiSecret = "32 bit random hex";
    pgUser           = "synapse";
    pgDatabase       = "synapse";
    pgPassword       = "SynapseSecurePass123";
    images = {
      livekit = "livekit/livekit-server:v1.8.2";
      jwtSvc  = "ghcr.io/element-hq/lk-jwt-service:latest";
    };
    livekitDir = "/srv/matrix/livekit";
    synapseDir = "/srv/matrix/synapse";
  };

  mkWellKnown = data: ''
    default_type application/json;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Cache-Control "no-store" always;
    return 200 '${builtins.toJSON data}';
  '';

  synapsePreStart = pkgs.writeShellScript "synapse-pre-start" ''
    chown -R matrix-synapse:matrix-synapse ${cfg.synapseDir} 2>/dev/null || true
  '';

in {

# ══════════════════════════════════════════════════════════════════════════
# ACME / Let's Encrypt
# ══════════════════════════════════════════════════════════════════════════
# NixOS делает всё сам:
#   1. acme-setup.service        — создаёт /var/lib/acme/.minica/, права
#   2. acme-selfsigned-X.service — self-signed заглушка ДО старта nginx
#   3. nginx стартует с заглушкой, отвечает на HTTP-01 challenge
#   4. acme-X.service            — получает настоящий cert от Let's Encrypt
#   5. nginx делает reload       — подхватывает настоящий cert
  security.acme = {
    acceptTerms = true;
    defaults.email = cfg.adminEmail;
  };

  # Cert для turn домена. group="nginx" обязателен — NixOS требует чтобы
  # nginx мог читать cert для домена, который он обслуживает (ACME challenge).
  # turnserver добавляем в группу nginx чтобы он тоже мог читать.
  security.acme.certs."${cfg.turnFqdn}" = {
    group   = "nginx";
    postRun = "systemctl restart coturn.service || true";
  };

  # После обновления основного cert — перезапустить LiveKit (bind-mount cert файлов).
  security.acme.certs."${cfg.serverName}" = {
    postRun = "chmod 644 /var/lib/acme/${cfg.serverName}/fullchain.pem /var/lib/acme/${cfg.serverName}/key.pem || true; systemctl restart docker-livekit.service || true";
  };

  # turnserver в группе nginx — чтобы читать cert из /var/lib/acme/turn.*/ (drwxr-x--- acme:nginx)
  users.users.turnserver.extraGroups = [ "nginx" ];

# ══════════════════════════════════════════════════════════════════════════
# Директории
# ══════════════════════════════════════════════════════════════════════════
  systemd.tmpfiles.rules = [
    "d  ${cfg.synapseDir}             0750 matrix-synapse matrix-synapse -"
    "d  ${cfg.synapseDir}/media_store 0750 matrix-synapse matrix-synapse -"
    "d  ${cfg.synapseDir}/uploads     0750 matrix-synapse matrix-synapse -"
    "d  /etc/secrets                  0750 root           matrix-synapse -"
    "d  ${cfg.livekitDir}             0755 root           root           -"
  ];

# ══════════════════════════════════════════════════════════════════════════
# Зависимости сервисов
# ══════════════════════════════════════════════════════════════════════════

  # coturn нужен настоящий cert (не self-signed) — стартует после ACME
  systemd.services.coturn = {
    after  = [ "acme-finished-${cfg.turnFqdn}.target" ];
    wants  = [ "acme-finished-${cfg.turnFqdn}.target" ];
  };

  # LiveKit: bind-mount cert файлов — нужен настоящий cert
  systemd.services."docker-livekit" = {
    after  = [ "acme-finished-${cfg.serverName}.target" ];
    wants  = [ "acme-finished-${cfg.serverName}.target" ];
  };
  systemd.services."docker-lk-jwt-service" = {
    after  = [ "acme-finished-${cfg.serverName}.target" "docker-livekit.service" ];
    wants  = [ "acme-finished-${cfg.serverName}.target" ];
  };

  # Synapse: после PostgreSQL
  systemd.services.matrix-synapse = {
    after  = [ "postgresql-synapse-setup.service" "systemd-tmpfiles-setup.service" ];
    wants  = [ "postgresql-synapse-setup.service" ];
    serviceConfig.ExecStartPre = [ ("+" + toString synapsePreStart) ];
  };

# ══════════════════════════════════════════════════════════════════════════
# PostgreSQL setup — идемпотентный oneshot
# ══════════════════════════════════════════════════════════════════════════
  services.postgresql = {
    enable   = true;
    package  = pkgs.postgresql_16;
    settings.max_connections = 100;
  };

  systemd.services."postgresql-synapse-setup" = {
    description   = "Idempotent PostgreSQL setup for Synapse";
    after         = [ "postgresql.service" ];
    requires      = [ "postgresql.service" ];
    before        = [ "matrix-synapse.service" ];
    wantedBy      = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "postgres";
    };
    script = ''
      ${pkgs.postgresql_16}/bin/psql postgres -c "
        DO \$\$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${cfg.pgUser}') THEN
            CREATE ROLE \"${cfg.pgUser}\" WITH LOGIN PASSWORD '${cfg.pgPassword}';
          ELSE
            ALTER ROLE \"${cfg.pgUser}\" WITH LOGIN PASSWORD '${cfg.pgPassword}';
          END IF;
        END \$\$;
      "
      if ! ${pkgs.postgresql_16}/bin/psql postgres -tAc \
          "SELECT 1 FROM pg_database WHERE datname='${cfg.pgDatabase}'" | grep -q 1; then
        ${pkgs.postgresql_16}/bin/psql postgres -c "
          CREATE DATABASE \"${cfg.pgDatabase}\"
            ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'
            TEMPLATE template0 OWNER \"${cfg.pgUser}\";
        "
      fi
      ${pkgs.postgresql_16}/bin/psql postgres -c \
        "GRANT ALL PRIVILEGES ON DATABASE \"${cfg.pgDatabase}\" TO \"${cfg.pgUser}\";"
      ${pkgs.postgresql_16}/bin/psql "${cfg.pgDatabase}" -c \
        "GRANT ALL ON SCHEMA public TO \"${cfg.pgUser}\";"
    '';
  };

# ══════════════════════════════════════════════════════════════════════════
# Element Web
# ══════════════════════════════════════════════════════════════════════════
  environment.etc."element-web/config.json" = {
    text = builtins.toJSON {
      default_server_config."m.homeserver" = {
        base_url    = "https://${cfg.serverName}";
        server_name = cfg.serverName;
      };
      disable_custom_urls = true;
      brand               = "Sheglo Project";
      features            = { feature_group_calls = true; };
      element_call        = { use_exclusively = true; };
    };
    mode = "0644";
  };

# ══════════════════════════════════════════════════════════════════════════
# Nginx
# ══════════════════════════════════════════════════════════════════════════
  services.nginx = {
    enable                   = true;
    recommendedProxySettings = true;
    recommendedTlsSettings   = true;
    recommendedOptimisation  = true;
    recommendedGzipSettings  = true;
    appendHttpConfig = ''
      map $http_upgrade $connection_upgrade {
        default   close;
        websocket upgrade;
      }
      limit_req_zone $binary_remote_addr zone=jwt:10m rate=10r/s;
    '';

    virtualHosts = {

      # turn.example.com — только для ACME challenge, coturn не через nginx
      "${cfg.turnFqdn}" = {
        enableACME = true;
        forceSSL   = true;
        locations."/".return = "404";
      };

      # matrix.example.com — основной
      "${cfg.serverName}" = {
        enableACME  = true;
        forceSSL    = true;
        http2       = true;
        extraConfig = ''
          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
          client_max_body_size 100m;
        '';
        locations = {
          "= /.well-known/matrix/client".extraConfig = mkWellKnown {
            "m.homeserver"."base_url" = "https://${cfg.serverName}";
            "org.matrix.msc4143.rtc_foci" = [{
              "type"                = "livekit";
              "livekit_service_url" = "https://${cfg.serverName}/livekit/jwt";
            }];
          };
          "= /.well-known/matrix/server".extraConfig = mkWellKnown {
            "m.server" = "${cfg.serverName}:443";
          };
          "~ ^/(_matrix|_synapse/client)" = {
            proxyPass   = "http://127.0.0.1:8008";
            extraConfig = ''
              proxy_http_version 1.1;
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              proxy_buffering    off;
            '';
          };
          "^~ /_synapse/admin/" = {
            proxyPass   = "http://127.0.0.1:8008";
            extraConfig = ''
              allow 127.0.0.1;
              deny all;
              proxy_http_version 1.1;
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              proxy_buffering    off;
            '';
          };
          "^~ /livekit/sfu/twirp/" = {
            proxyPass   = "http://127.0.0.1:7880/twirp/";
            extraConfig = ''
              proxy_http_version        1.1;
              proxy_buffering           off;
              proxy_request_buffering   off;
              proxy_set_header Upgrade  $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
            '';
          };
          "^~ /livekit/sfu/" = {
            proxyPass   = "http://127.0.0.1:7880/";
            extraConfig = ''
              proxy_http_version        1.1;
              proxy_send_timeout        3600;
              proxy_read_timeout        3600;
              proxy_buffering           off;
              proxy_set_header Upgrade  $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
            '';
          };
          # Element Call: /livekit/jwt/sfu/get → 8088/sfu/get
          # nginx автоматически срезает prefix /livekit/jwt/ т.к. proxyPass оканчивается на /
          "^~ /livekit/jwt/" = {
            proxyPass   = "http://127.0.0.1:8088/";
            extraConfig = ''
              limit_req zone=jwt burst=20 nodelay;
              limit_req_status 429;
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
            '';
          };
          "= /livekit/jwt/healthz".proxyPass = "http://127.0.0.1:8088/healthz";
        };
      };

      # matrix.example.com:8448 — federation
      "${cfg.serverName}-federation" = {
        serverName  = cfg.serverName;
        forceSSL    = true;
        useACMEHost = cfg.serverName;
        http2       = true;
        listen      = [{ addr = "0.0.0.0"; port = 8448; ssl = true; }];
        locations = {
          "~ ^/(_matrix|_synapse/client)" = {
            proxyPass   = "http://127.0.0.1:8008";
            extraConfig = ''
              proxy_http_version 1.1;
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              proxy_buffering    off;
            '';
          };
          "/".return = "404";
        };
      };

      # element.example.com
      "${cfg.elementFqdn}" = {
        enableACME  = true;
        forceSSL    = true;
        http2       = true;
        root        = "${pkgs.element-web}";
        locations = {
          "/" = {
            index    = "index.html";
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              add_header Cache-Control "no-cache" always;
              add_header X-Frame-Options SAMEORIGIN always;
              add_header X-Content-Type-Options nosniff always;
              add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            '';
          };
          "= /config.json" = {
            alias = "/etc/element-web/config.json";
            extraConfig = ''
              default_type application/json;
              add_header Cache-Control "no-store" always;
              add_header X-Frame-Options SAMEORIGIN always;
              add_header X-Content-Type-Options nosniff always;
              add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            '';
          };
          "~* \\.(js|css|woff2|png|svg|ico)$".extraConfig = ''
            add_header Cache-Control "public, max-age=31536000, immutable" always;
          '';
        };
      };

    };
  };

# ══════════════════════════════════════════════════════════════════════════
# Coturn — TURN для legacy 1:1 VoIP звонков
# ══════════════════════════════════════════════════════════════════════════
  services.coturn = {
    enable          = true;
    no-cli          = true;
    no-tcp-relay    = true;
    min-port        = 49000;
    max-port        = 50000;
    use-auth-secret = true;
    static-auth-secret-file = "/var/lib/coturn/turn-secret";
    realm = cfg.turnFqdn;
    # group = "turnserver" на cert выше — coturn читает напрямую без хаков с группами
    cert  = "${config.security.acme.certs.${cfg.turnFqdn}.directory}/fullchain.pem";
    pkey  = "${config.security.acme.certs.${cfg.turnFqdn}.directory}/key.pem";
    extraConfig = ''
      no-multicast-peers
      denied-peer-ip=0.0.0.0-0.255.255.255
      denied-peer-ip=10.0.0.0-10.255.255.255
      denied-peer-ip=100.64.0.0-100.127.255.255
      denied-peer-ip=127.0.0.0-127.255.255.255
      denied-peer-ip=169.254.0.0-169.254.255.255
      denied-peer-ip=172.16.0.0-172.31.255.255
      denied-peer-ip=192.0.0.0-192.0.0.255
      denied-peer-ip=192.168.0.0-192.168.255.255
      denied-peer-ip=198.18.0.0-198.19.255.255
      syslog
    '';
  };

# ══════════════════════════════════════════════════════════════════════════
# Matrix Synapse
# ══════════════════════════════════════════════════════════════════════════
  services.matrix-synapse = {
    enable = true;
    settings = {
      server_name    = cfg.serverName;
      public_baseurl = "https://${cfg.serverName}/";
      report_stats   = false;

      listeners = [{
        port           = 8008;
        bind_addresses = [ "127.0.0.1" ];
        type           = "http";
        tls            = false;
        x_forwarded    = true;
        resources      = [{ names = [ "client" "federation" ]; compress = false; }];
      }];

      database = {
        name = "psycopg2";
        args = {
          user     = cfg.pgUser;
          password = cfg.pgPassword;
          database = cfg.pgDatabase;
          host     = "localhost";
          port     = 5432;
          cp_min   = 5;
          cp_max   = 10;
        };
      };

      media_store_path = "${cfg.synapseDir}/media_store";
      uploads_path     = "${cfg.synapseDir}/uploads";

      # turn_shared_secret — из synapse-extra.yaml (генерируется ниже)
      turn_uris = [
        "turns:${cfg.turnFqdn}:5349?transport=udp"
        "turns:${cfg.turnFqdn}:5349?transport=tcp"
        "turn:${cfg.turnFqdn}:3478?transport=udp"
        "turn:${cfg.turnFqdn}:3478?transport=tcp"
      ];
      turn_user_lifetime = "1h";
      turn_allow_guests  = true;

      rc_login = {
        address         = { burst_count = 5;  per_second = 0.5; };
        account         = { burst_count = 5;  per_second = 0.2; };
        failed_attempts = { burst_count = 3;  per_second = 0.1; };
      };
      rc_registration = { burst_count = 3;  per_second = 0.05; };
      rc_message      = { per_second = 0.4; burst_count = 15; };
      rc_federation = {
        window_size  = 1000;
        sleep_limit  = 10;
        sleep_delay  = 500;
        reject_limit = 50;
        concurrent   = 3;
      };

      default_room_version        = "11";
      enable_registration         = false;
      suppress_key_server_warning = true;
      trusted_key_servers         = [{ server_name = "matrix.org"; }];

      log_config = pkgs.writeText "synapse-log.yaml" ''
        version: 1
        formatters:
          precise:
            format: '%(asctime)s - %(levelname)s - %(request)s - %(message)s'
        handlers:
          console:
            class: logging.StreamHandler
            formatter: precise
        loggers:
          synapse:             { level: WARNING }
          synapse.storage.SQL: { level: WARNING }
        root:
          level: WARNING
          handlers: [console]
        disable_existing_loggers: false
      '';
    };
    # macaroon_secret_key, registration_shared_secret, form_secret, turn_shared_secret
    extraConfigFiles = [ "/etc/secrets/synapse-extra.yaml" ];
  };

# ══════════════════════════════════════════════════════════════════════════
# LiveKit + JWT service (Element Call / VoIP)
# ══════════════════════════════════════════════════════════════════════════
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      "livekit" = {
        image     = cfg.images.livekit;
        cmd       = [ "--config" "/etc/livekit/livekit.yaml" ];
        autoStart = true;
        volumes = [
          "${cfg.livekitDir}/livekit.yaml:/etc/livekit/livekit.yaml:ro"
          "/var/lib/acme/${cfg.serverName}/fullchain.pem:/etc/livekit/certs/fullchain.cer:ro"
          "/var/lib/acme/${cfg.serverName}/key.pem:/etc/livekit/certs/privkey.key:ro"
        ];
        extraOptions = [ 
    "--network=host" 
    "--ulimit" "nofile=65535:65535" 
  ];      
};
"lk-jwt-service" = {
  image        = cfg.images.jwtSvc;
  autoStart    = true;
  dependsOn    = [ "livekit" ];
  extraOptions = [
    "--network=host"
    # МЕНЯЕМ ЭТО: направляем matrix:// запросы на локальный порт Synapse
    "--add-host" "${cfg.serverName}:127.0.0.1"
  ];
  environment = {
    LIVEKIT_URL                     = "wss://${cfg.serverName}/livekit/sfu";
    LIVEKIT_KEY                     = cfg.livekitApiKey;
    LIVEKIT_SECRET                  = cfg.livekitApiSecret;
    LIVEKIT_JWT_BIND                = ":8088";
    LIVEKIT_FULL_ACCESS_HOMESERVERS = cfg.serverName;
    
    # ФОКУС: Переопределяем URL для проверки OpenID. 
    # Сервис будет думать, что идет на https, но реально пойдет на http://127.0.0.1:8008
    MATRIX_HOMESERVER_URL           = "http://127.0.0.1:8008";
  };
  # Volumes можно даже убрать, раз мы уходим от SSL во внутренних запросах
};
    };
  };

  virtualisation.docker = {
    enable    = true;
    autoPrune = { enable = true; dates = "weekly"; };
  };

# ══════════════════════════════════════════════════════════════════════════
# Activation Scripts — запускаются ДО сервисов при каждом nixos-rebuild
# ══════════════════════════════════════════════════════════════════════════
  system.activationScripts."synapse-secrets" = {
    deps = [ "users" "groups" ];
    text = ''
      # ── Synapse секреты ────────────────────────────────────────────────
      install -d -m 750 -o root -g matrix-synapse /etc/secrets

      if [ ! -f /etc/secrets/synapse-extra.yaml ]; then
        M=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
        R=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
        F=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
        printf 'macaroon_secret_key: "%s"\nregistration_shared_secret: "%s"\nform_secret: "%s"\n' \
          "$M" "$R" "$F" > /etc/secrets/synapse-extra.yaml
      fi
      chown root:matrix-synapse /etc/secrets/synapse-extra.yaml
      chmod 640 /etc/secrets/synapse-extra.yaml

      # ── TURN секрет ────────────────────────────────────────────────────
      install -d -m 750 -o turnserver -g turnserver /var/lib/coturn

      if [ ! -f /var/lib/coturn/turn-secret ]; then
        T=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
        printf '%s' "$T" > /var/lib/coturn/turn-secret
        chown turnserver:turnserver /var/lib/coturn/turn-secret
        chmod 600 /var/lib/coturn/turn-secret
        printf '\nturn_shared_secret: "%s"\n' "$T" >> /etc/secrets/synapse-extra.yaml
      fi

      # Синхронизация: turn-secret есть, но в yaml нет → дописать
      if [ -f /var/lib/coturn/turn-secret ] && \
         ! grep -q 'turn_shared_secret' /etc/secrets/synapse-extra.yaml; then
        T=$(cat /var/lib/coturn/turn-secret)
        printf '\nturn_shared_secret: "%s"\n' "$T" >> /etc/secrets/synapse-extra.yaml
      fi
    '';
  };

  system.activationScripts."livekit-config" = {
  text = ''
    install -d -m 755 ${cfg.livekitDir}
    [ -d "${cfg.livekitDir}/livekit.yaml" ] && rm -rf "${cfg.livekitDir}/livekit.yaml"
    cat > ${cfg.livekitDir}/livekit.yaml << LKEOF
port: 7880
log_level: info
rtc:
  use_external_ip: true
  node_ip: ${cfg.livekitNodeIp}
  tcp_port: 7881
  udp_port: 7882
  port_range_start: 50100
  port_range_end: 50200
  stun_servers: ["stun.l.google.com:19302"]
turn:
  enabled: true
  udp_port: 443
  domain: ${cfg.turnFqdn}
  cert_file: /etc/livekit/certs/fullchain.cer
  key_file: /etc/livekit/certs/privkey.key
  relay_range_start: 50100
  relay_range_end: 50200
room:
  auto_create: false
keys:
  ${cfg.livekitApiKey}: "${cfg.livekitApiSecret}"
LKEOF
  '';
};
  system.activationScripts."synapse-dirs" = {
    deps = [ "users" "groups" ];
    text = ''
      install -d -m 750 -o matrix-synapse -g matrix-synapse \
        ${cfg.synapseDir} \
        ${cfg.synapseDir}/media_store \
        ${cfg.synapseDir}/uploads
    '';
  };

# ══════════════════════════════════════════════════════════════════════════
# Firewall
# ══════════════════════════════════════════════════════════════════════════
  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 80 443 8448 7881 7882 5349 3478 ];
    allowedUDPPorts = [ 443 7882 3478 5349 ];
    allowedUDPPortRanges = [
      { from = 49000; to = 50000; }   # coturn relay
      { from = 50100; to = 50200; }   # livekit relay
    ];
  };
}

