fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .compile_protos(&["../go-comparison/echo.proto", "../interop.proto"], &[".."])?;
    Ok(())
}
