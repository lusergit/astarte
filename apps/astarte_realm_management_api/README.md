Astarte Realm Management API
============================

Astarte Realm Management API serves a [REST
API](priv/static/astarte_realm_management_api.yaml) that allows administration
panels and applications to manage a certain realm.

## 🔧 Build
To build the Astarte Realm Management API, you need to have Elixir and Erlang
installed. You can find the installation instructions on the [Elixir
website](https://elixir-lang.org/install.html).
To build the project, run:

```bash
mix deps.get
mix compile
```

## 🎯 Testing
To run the tests, you need to have a running instance of Scylla (or Cassandra) and RabbitMQ.

- Ensure Scylla (or cassandra) is running and accessible.
  ```bash
  docker run --rm -d --name astarte-scylla -p 9042:9042 scylladb/scylla
  ```

- Ensure RabbitMQ is running and accessible.
  ```bash
    docker run --rm -d --name astarte-rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:management
  ```

- Run Astarte Realm Management tests:
  ```bash
  mix test
  ```
  
Alternatively, `mix coveralls` can be used to run the tests and generate a coverage report.

## 🚀 Run

`AppEngine` is one of the microservices that together compose Astarte. By
running the [Astarte in 5
minutes](https://docs.astarte-platform.org/astarte/latest/010-astarte_in_5_minutes.html)
guide all astarte services (including this one!) will be available to test.

Alternatively to test this single component (not in a production-like
environment), you can follow these steps:

- Ensure Scylla (or cassandra) is running and accessible.
  ```bash
  docker run --rm -d --name astarte-scylla -p 9042:9042 scylladb/scylla
  ```

- Ensure RabbitMQ is running and accessible.
  ```bash
    docker run --rm -d --name astarte-rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:management
  ```

- Run Astarte Realm Management:
  ```bash
  iex -S mix
  ```
