# install-sql-server

This action installs and runs SQL Server for a GitHub Actions workflow.

## Usage

Install SQL Server with a default database of `nservicebus` and put the connection string in the environment variable `SQL_SERVER_CONNECTION_STRING`:

```yaml
steps:
  - name: Install SQL Server
    uses: Particular/install-sql-server-action@main
    with:
      connection-string-env-var: SQL_SERVER_CONNECTION_STRING
      catalog: nservicebus
```

To add additional parameters to the end of the connection string, such as `Max Pool Size`. The connection string generated by the action already ends with a semicolon, and the `extra-params` are appended at the end.

```yaml
steps:
  - name: Install SQL Server
    uses: Particular/install-sql-server-action@main
    with:
      connection-string-env-var: SQL_SERVER_CONNECTION_STRING
      catalog: nservicebus
      extra-params: "Max Pool Size=100;"
```

## Parameters

| Parameter | Required | Default | Description |
|-|:-:|:-:|-|
| `connection-string-env-var` | Yes | - | Environment variable name that will be filled with the SQL connection string, which can then be used in successive steps. |
| `catalog` | No | `nservicebus` | The default catalog, which will be created by the action. |
| `extra-params` | No | - | Extra parameters to be appended to the end of the connection string |

## Using `sqlcmd`

The action creates the necessary environment variables so that `sqlcmd` can be used without any additional login parameters.

For example:

```yaml
steps:
  - name: Install SQL Server
    uses: Particular/install-sql-server-action@main
    with:
      connection-string-env-var: SQL_SERVER_CONNECTION_STRING
      catalog: nservicebus
  - name: Create schemas
    shell: pwsh
    run: |
        echo "Create additional schemas"
        sqlcmd -Q "CREATE SCHEMA receiver AUTHORIZATION db_owner" -d "nservicebus"
        sqlcmd -Q "CREATE SCHEMA sender AUTHORIZATION db_owner" -d "nservicebus"
        sqlcmd -Q "CREATE SCHEMA db@ AUTHORIZATION db_owner" -d "nservicebus"
```