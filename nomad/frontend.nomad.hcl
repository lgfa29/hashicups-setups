job "frontend" {
  group "public-api" {
    count = 2

    network {
      port "http" {}
    }

    service {
      name     = "public-api"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/health"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "api" {
      driver = "docker"

      config {
        image = "hashicorpdemoapp/public-api:v0.0.7"
        ports = ["http"]
      }

      template {
        data        = <<EOF
BIND_ADDRESS=':{{env "NOMAD_PORT_http"}}'
{{range nomadService 1 (env "NOMAD_ALLOC_ID") "products-api"}}
PRODUCT_API_URI=http://{{.Address}}:{{.Port}}
{{end}}
{{range nomadService 1 (env "NOMAD_ALLOC_ID") "payments-api"}}
PAYMENT_API_URI=http://{{.Address}}:{{.Port}}
{{end}}
EOF
        destination = "${NOMAD_SECRETS_DIR}/env"
        env         = true
      }

      resources {
        cpu    = 50
        memory = 10
      }
    }
  }

  group "ui" {
    network {
      port "http" {}
    }

    service {
      name     = "ui"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "ui" {
      driver = "docker"

      config {
        image = "hashicorpdemoapp/frontend:v1.0.9"
        ports = ["http"]
      }

      env {
        PORT                       = NOMAD_PORT_http
        NEXT_PUBLIC_PUBLIC_API_URL = "/"
      }

      resources {
        cpu    = 50
        memory = 150
      }
    }
  }

  group "proxy" {
    network {
      port "http" {
        static = 80
      }
    }

    service {
      name     = "nginx"
      port     = "http"
      provider = "nomad"

      check {
        name     = "ui"
        type     = "http"
        path     = "/"
        interval = "5s"
        timeout  = "3s"
      }

      check {
        name     = "api"
        type     = "http"
        path     = "/api/health"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "proxy" {
      driver = "docker"

      config {
        image = "nginx:alpine"
        ports = ["http"]

        mount {
          type   = "bind"
          source = "local/default.conf"
          target = "/etc/nginx/conf.d/default.conf"
        }
      }

      template {
        data        = <<EOF
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=STATIC:10m inactive=7d use_temp_path=off;

upstream frontend_upstream {
{{range nomadService "ui"}}
  server {{.Address}}:{{.Port}};
{{end}}
}

upstream api_upstream {
{{range nomadService "public-api"}}
  server {{.Address}}:{{.Port}};
{{end}}
}

server {
  listen {{ env "NOMAD_PORT_http" }};
  server_name {{ env "NOMAD_IP_http" }};
  server_tokens off;
  gzip on;
  gzip_proxied any;
  gzip_comp_level 4;
  gzip_types text/css application/javascript image/svg+xml;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection 'upgrade';
  proxy_set_header Host $host;
  proxy_cache_bypass $http_upgrade;

  location /api {
    proxy_pass http://api_upstream;
  }

  location = /api/health {
    proxy_pass http://api_upstream/health;
  }

  location /_next/static {
    proxy_cache STATIC;
    proxy_pass http://frontend_upstream;
  }

  location /static {
    proxy_cache STATIC;
    proxy_ignore_headers Cache-Control;
    proxy_cache_valid 60m;
    proxy_pass http://frontend_upstream;
  }

  location / {
    proxy_pass http://frontend_upstream;
  }
}
        EOF
        destination = "local/default.conf"
      }

      resources {
        cpu    = 100
        memory = 20
      }
    }
  }
}
