// services/api/src/effectivnost_360/otp.gleam
//
// Thin wrapper over the OTP-application control that the API entry point
// needs before it can open a PostgreSQL connection pool.
//
// `gleam_erlang` 1.3.0 exposes no generic Erlang MFA-call helper, so the
// single required primitive (`application:ensure_all_started/1`) is provided
// by `effectivnost_360_otp_ffi.erl`.

/// Starts an OTP application and its dependencies, if not already running.
///
/// Idempotent: calling it twice is safe - the second call is a no-op.
/// Raises if the application cannot be started.
@external(erlang, "effectivnost_360_otp_ffi", "ensure_all_started")
pub fn ensure_all_started(application: String) -> Nil
