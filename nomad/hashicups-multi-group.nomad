variable "datacenters" {
  description = "A list of datacenters in the region which are eligible for task placement."
  type        = list(string)
  default     = ["*"]
}

variable "region" {
  description = "The region where the job should be placed."
  type        = string
  default     = "global"
}

variable "frontend_version" {
  description = "Docker version tag"
  default     = "v1.0.9"
}

variable "public_api_version" {
  description = "Docker version tag"
  default     = "v0.0.7"
}

variable "payments_version" {
  description = "Docker version tag"
  default     = "v0.0.16"
}

variable "product_api_version" {
  description = "Docker version tag"
  default     = "v0.0.22"
}

variable "product_api_db_version" {
  description = "Docker version tag"
  default     = "v0.0.22"
}

variable "postgres_db" {
  description = "Postgres DB name"
  default     = "products"
}

variable "postgres_user" {
  description = "Postgres DB User"
  default     = "postgres"
}

variable "postgres_password" {
  description = "Postgres DB Password"
  default     = "password"
}

variable "nginx_port" {
  description = "Nginx Port"
  default     = 80
}

# Begin Job Spec

job "hashicups" {
  type        = "service"
  region      = var.region
  datacenters = var.datacenters

  group "db" {
    network {
      port "db" {
        to = 5432
      }
    }

    service {
      name     = "db"
      port     = "db"
      provider = "nomad"

      check {
        type     = "tcp"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "db" {
      driver = "docker"

      meta {
        service = "database"
      }

      config {
        image = "hashicorpdemoapp/product-api-db:${var.product_api_db_version}"
        ports = ["db"]
      }

      env {
        POSTGRES_DB       = var.postgres_db
        POSTGRES_USER     = var.postgres_user
        POSTGRES_PASSWORD = var.postgres_password
      }

      resources {
        cpu    = 500
        memory = 300
      }
    }
  }

  group "product-api" {
    network {
      port "http" {}
    }

    service {
      name     = "products-api"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/health/readyz"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "product-api" {
      driver = "docker"

      meta {
        service = "product-api"
      }

      config {
        image = "hashicorpdemoapp/product-api:${var.product_api_version}"
        ports = ["http"]
      }

      env {
        BIND_ADDRESS = "0.0.0.0:${NOMAD_PORT_http}"
      }

      template {
        data        = <<EOF
{{range nomadService 1 (env "NOMAD_ALLOC_ID") "db"}}
DB_CONNECTION='host={{.Address}} port={{.Port}} user=${var.postgres_user} password=${var.postgres_password} dbname=${var.postgres_db} sslmode=disable'
{{end}}
EOF
        destination = "secrets/env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 32
      }
    }
  }

  group "payments-api" {
    network {
      port "http" {}
    }

    service {
      name     = "payments-api"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/actuator/health"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "payments-api" {
      driver = "docker"

      meta {
        service = "payments-api"
      }

      config {
        image = "hashicorpdemoapp/payments:${var.payments_version}"
        ports = ["http"]

        mount {
          type   = "bind"
          source = "secrets/application.yaml"
          target = "/application.yaml"
        }
      }

      template {
        data        = <<EOF
server:
  port: "{{env "NOMAD_PORT_http"}}"
spring:
  datasource:
    driver-class-name: org.postgresql.Driver
    url: jdbc:postgresql://{{range nomadService 1 (env "NOMAD_ALLOC_ID") "db"}}{{.Address}}:{{.Port}}/postgres{{end}}
    username: ${var.postgres_user}
    password: ${var.postgres_password}
  jpa:
    hibernate:
      ddl-auto: update
    show-sql: true
    database: postgresql
    database-platform: org.hibernate.dialect.PostgreSQLDialect
    open-in-view: false
    generate-ddl: true
    properties:
      hibernate:
        temp:
          use_jdbc_metadata_defaults: false
management:
  endpoint:
    health:
      show-details: always
EOF
        destination = "secrets/application.yaml"
      }

      resources {
        cpu    = 100
        memory = 600
      }
    }
  }

  group "public-api" {
    network {
      port "http" {}
    }

    service {
      name     = "public-api"
      port     = "http"
      provider = "nomad"
    }

    task "public-api" {
      driver = "docker"

      meta {
        service = "public-api"
      }

      config {
        image = "hashicorpdemoapp/public-api:${var.public_api_version}"
        ports = ["http"]
      }

      template {
        data        = <<EOF
BIND_ADDRESS=':{{env "NOMAD_PORT_http"}}'

{{- range nomadService 1 (env "NOMAD_ALLOC_ID") "products-api"}}
PRODUCT_API_URI=http://{{.Address}}:{{.Port}}
{{end}}

{{- range nomadService 1 (env "NOMAD_ALLOC_ID") "payments-api"}}
PAYMENT_API_URI=http://{{.Address}}:{{.Port}}
{{end}}
EOF
        destination = "local/env"
        env         = true
      }

      resources {
        cpu    = 150
        memory = 32
      }
    }
  }

  group "frontend" {
    network {
      port "http" {}
    }

    service {
      name     = "frontend"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "frontend" {
      driver = "docker"

      meta {
        service = "frontend"
      }

      config {
        image = "hashicorpdemoapp/frontend:${var.frontend_version}"
        ports = ["http"]
      }

      env {
        PORT = NOMAD_PORT_http
      }

      template {
        data        = <<EOF
{{range nomadService 1 (env "NOMAD_ALLOC_ID") "public-api"}}
NEXT_PUBLIC_PUBLIC_API_URL=http://{{.Address}}:{{.Port}}
{{end}}
EOF
        destination = "local/env"
        env         = true
      }

      resources {
        cpu    = 50
        memory = 300
      }
    }
  }

  group "proxy" {
    network {
      port "http" {
        static = var.nginx_port
      }
    }

    service {
      name     = "proxy"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/"
        interval = "5s"
        timeout  = "3s"
      }
    }

    task "nginx" {
      driver = "docker"

      meta {
        service = "nginx-reverse-proxy"
      }

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
upstream frontend_upstream {
{{range nomadService "frontend"}}
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

  location /_next/static {
    proxy_pass http://frontend_upstream;
  }

  location /static {
    proxy_pass http://frontend_upstream;
  }

  location / {
    proxy_pass http://frontend_upstream;
  }

  location /api {
    proxy_pass http://api_upstream;
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
