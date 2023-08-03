job "backend" {
  group "products" {
    count = 2

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

    task "api" {
      driver = "docker"

      config {
        image = "hashicorpdemoapp/product-api:v0.0.22"
        ports = ["http"]
      }

      env {
        BIND_ADDRESS = "0.0.0.0:${NOMAD_PORT_http}"
      }

      template {
        data        = <<EOF
{{range nomadService 1 (env "NOMAD_ALLOC_ID") "db"}}
DB_CONNECTION='host={{.Address}} port={{.Port}} user=postgres password=password dbname=products sslmode=disable'
{{end}}
EOF
        destination = "${NOMAD_SECRETS_DIR}/db.env"
        env         = true
      }

      resources {
        cpu    = 50
        memory = 50
      }
    }
  }

  group "payments" {
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

    task "api" {
      driver = "docker"

      config {
        image = "hashicorpdemoapp/payments:v0.0.16"
        ports = ["http"]

        mount {
          type   = "bind"
          source = "local/application.yaml"
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
    username: postgres
    password: password
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
        destination = "${NOMAD_TASK_DIR}/application.yaml"
      }

      resources {
        cpu    = 100
        memory = 350
      }
    }
  }

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

    task "postgres" {
      driver = "docker"

      config {
        image = "hashicorpdemoapp/product-api-db:v0.0.22"
        ports = ["db"]
      }

      env {
        POSTGRES_DB       = "products"
        POSTGRES_USER     = "postgres"
        POSTGRES_PASSWORD = "password"
      }

      resources {
        cpu    = 100
        memory = 300
      }
    }
  }
}
