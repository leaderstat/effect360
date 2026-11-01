import common_sql as sql
import gleam/dynamic/decode
import gleam/result

pub type CreatedRequest {
  CreatedRequest(id: String, created: Bool)
}

pub fn ready(driver: sql.Driver(conn), database_url: String) -> Result(Nil, sql.DbError) {
  let decoder = {
    use value <- decode.field(0, decode.int)
    decode.success(value)
  }
  sql.with_connection(driver, database_url, fn(conn) {
    use _ <- result.try(
      sql.execute(
        driver,
        conn,
        sql.Sql("SELECT 1"),
        [],
        decoder,
      ),
    )
    Ok(Nil)
  })
}

pub fn create_request(
  driver: sql.Driver(conn),
  database_url: String,
  requester_id: String,
  idempotency_key: String,
  text: String,
) -> Result(CreatedRequest, sql.DbError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use created <- decode.field(1, decode.bool)
    decode.success(CreatedRequest(id:, created:))
  }
  let query = "
    WITH inserted AS (
      INSERT INTO requests (idempotency_key, raw_text, requester_id)
      VALUES ($1, $2, $3::uuid)
      ON CONFLICT (idempotency_key) DO NOTHING
      RETURNING id, raw_text
    ), queued_job AS (
      INSERT INTO job_runs (
        request_id,
        job_type,
        idempotency_key,
        input_hash
      )
      SELECT
        inserted.id,
        'classify_and_extract',
        'request:' || inserted.id::text,
        encode(digest(inserted.raw_text, 'sha256'), 'hex')
      FROM inserted
      RETURNING id, request_id
    ), queued AS (
      INSERT INTO outbox (subject, payload)
      SELECT
        'requests.created',
        jsonb_build_object(
          'schema_version', 1,
          'job_type', 'classify_and_extract',
          'job_id', queued_job.id::text,
          'request_id', queued_job.request_id::text,
          'raw_text', inserted.raw_text
        )
      FROM queued_job
      JOIN inserted ON inserted.id = queued_job.request_id
      RETURNING id
    ), result AS (
      SELECT inserted.id, true AS created
      FROM inserted
      JOIN queued ON true
      UNION ALL
      SELECT id, false AS created
      FROM requests
      WHERE idempotency_key = $1
    )
        SELECT id::text, created FROM result LIMIT 1
    "
    sql.with_connection(driver, database_url, fn(conn) {
      case sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(idempotency_key), sql.PString(text), sql.PString(requester_id)],
        decoder,
      ) {
      Ok([request]) -> Ok(request)
      Ok(_) -> Error(sql.QueryError("Request insert returned no row"))
      Error(error) -> Error(error)
    }
  })
}
