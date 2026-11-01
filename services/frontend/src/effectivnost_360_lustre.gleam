// services/frontend/src/effectivnost_360_lustre.gleam
//
// Entry point of the frontend package.
//
// Gleam's JavaScript target looks for a module named after the package
// (`effectivnost_360_lustre`) and calls its `main` function. The actual
// Lustre application lives in `effectivnost_360_lustre/app.gleam`; this
// module only forwards to it so that the entry point stays trivial and
// the application logic remains in one place.

import effectivnost_360_lustre/app

pub fn main() {
  app.main()
}
