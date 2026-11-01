import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import mist
import common_sql_postgresql
import effectivnost_360/otp
import effectivnost_360/router
import wisp
import wisp_mist

pub fn main() {
  wisp.configure_logger()
  let assert Ok(database_url) = envoy.get("DATABASE_URL")
  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let port =
    envoy.get("PORT")
    |> result.unwrap("8000")
    |> int.parse
    |> result.unwrap(8000)

  // The PostgreSQL stack is made of two OTP applications that own process
  // state the driver depends on:
  //
  //   * `pg_types` — owns the `pg_types_table` ETS table that
  //     `pg_types:update/3` writes the connection type map into. Without the
  //     application the write fails with `badarg` (`ets:insert` on a table
  //     that does not exist).
  //   * `pgo` — owns the `pgo_query_cache` ETS table that every query goes
  //     through (`pgo_handler:extended_query/6` looks the statement up before
  //     sending it). Without the application the lookup fails with `badarg`
  //     (`ets:lookup` on a table that does not exist).
  //
  // This project is started with `-s effectivnost_360_api main` (see
  // services/api/Dockerfile) and NOT through an OTP release, so the
  // `applications` list of the generated `.app` files is never applied and
  // neither application would be started on its own. `pog:start/1` only
  // starts a connection pool — it does not start the applications.
  //
  // `ensure_all_started` is idempotent, so it is safe to call here. Starting
  // `pgo` does not create any pool by itself: `pgo_app:start/2` only reads
  // the `pgo`/`pools` environment variable, which stays empty — the pool is
  // created later by `pog:start/1` through the driver.
  otp.ensure_all_started("pg_types")
  otp.ensure_all_started("pgo")

  let context =
    router.Context(
      driver: common_sql_postgresql.driver(),
      database_url: database_url,
    )

  let handler = router.handle_request(_, context)
  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}
