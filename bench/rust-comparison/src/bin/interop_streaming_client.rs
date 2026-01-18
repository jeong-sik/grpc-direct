use tonic::Request;
use tonic::codec::CompressionEncoding;
use tonic::transport::{Certificate, ClientTlsConfig, Endpoint, Identity};
pub mod interop {
    tonic::include_proto!("interop");
}

use interop::interop_service_client::InteropServiceClient;
use interop::Payload;

fn usage() -> &'static str {
    "Usage: interop_streaming_client [--target http://127.0.0.1:50051] [--ca path] [--cert path --key path] [--gzip] [--message hello] [--stream-count 100] [--cancel-after 5] [--wait-goaway] [--skip-bidi] [--skip-cancel]"
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut target = "http://127.0.0.1:50051".to_string();
    let mut ca_file: Option<String> = None;
    let mut cert_file: Option<String> = None;
    let mut key_file: Option<String> = None;
    let mut message = "hello".to_string();
    let mut stream_count = 100usize;
    let mut cancel_after = 5usize;
    let mut wait_goaway = false;
    let mut skip_bidi = false;
    let mut skip_cancel = false;
    let mut enable_gzip = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--target" => {
                target = args.next().unwrap_or_else(|| target.clone());
            }
            "--ca" => {
                ca_file = args.next();
            }
            "--cert" => {
                cert_file = args.next();
            }
            "--key" => {
                key_file = args.next();
            }
            "--message" => {
                message = args.next().unwrap_or_else(|| message.clone());
            }
            "--stream-count" => {
                stream_count = args
                    .next()
                    .and_then(|v| v.parse::<usize>().ok())
                    .unwrap_or(stream_count);
            }
            "--cancel-after" => {
                cancel_after = args
                    .next()
                    .and_then(|v| v.parse::<usize>().ok())
                    .unwrap_or(cancel_after);
            }
            "--wait-goaway" => {
                wait_goaway = true;
            }
            "--skip-bidi" => {
                skip_bidi = true;
            }
            "--skip-cancel" => {
                skip_cancel = true;
            }
            "--gzip" => {
                enable_gzip = true;
            }
            "--help" => {
                eprintln!("{}", usage());
                return Ok(());
            }
            _ => {
                eprintln!("Unknown arg: {}", arg);
                eprintln!("{}", usage());
                return Ok(());
            }
        }
    }

    let endpoint = Endpoint::from_shared(target.clone())?;
    let channel = if target.starts_with("https://") {
        let ca_path = match ca_file {
            Some(path) => path,
            None => {
                eprintln!("missing --ca for https target");
                return Ok(());
            }
        };
        if cert_file.is_some() ^ key_file.is_some() {
            eprintln!("--cert and --key must be provided together");
            return Ok(());
        }
        let ca = std::fs::read(ca_path)?;
        let mut tls = ClientTlsConfig::new().ca_certificate(Certificate::from_pem(ca));
        if let (Some(cert_path), Some(key_path)) = (cert_file, key_file) {
            let cert = std::fs::read(cert_path)?;
            let key = std::fs::read(key_path)?;
            tls = tls.identity(Identity::from_pem(cert, key));
        }
        endpoint.tls_config(tls)?.connect().await?
    } else {
        endpoint.connect().await?
    };

    let mut client = InteropServiceClient::new(channel);
    if enable_gzip {
        client = client
            .send_compressed(CompressionEncoding::Gzip)
            .accept_compressed(CompressionEncoding::Gzip);
    }

    let response = client
        .unary(Request::new(Payload {
            message: message.clone(),
        }))
        .await?;
    println!("unary resp: {}", response.into_inner().message);

    let mut stream = client
        .server_stream(Request::new(Payload {
            message: message.clone(),
        }))
        .await?
        .into_inner();
    let mut count = 0usize;
    while let Some(resp) = stream.message().await? {
        let _ = resp.message;
        count += 1;
    }
    println!("server streaming recv count: {}", count);
    if count == 0 {
        return Err("server streaming returned 0 messages".into());
    }
    if count != stream_count {
        println!("server streaming count mismatch: expected {}, got {}", stream_count, count);
    }

    let message_for_stream = message.clone();
    let outbound = tokio_stream::iter((0..3).map(move |i| Payload {
        message: format!("{}-{}", message_for_stream, i),
    }));
    let response = client.client_stream(Request::new(outbound)).await?;
    println!("client streaming resp: {}", response.into_inner().message);

    if !skip_bidi {
        let mut bidi_payloads = Vec::with_capacity(4);
        for i in 0..3 {
            bidi_payloads.push(Payload {
                message: format!("{}-{}", message, i),
            });
        }
        bidi_payloads.push(Payload {
            message: "__END__".to_string(),
        });
        let outbound = tokio_stream::iter(bidi_payloads);
        let response = client.bidi_stream(Request::new(outbound)).await?;
        let mut inbound = response.into_inner();

        let mut bidi_count = 0usize;
        while let Some(resp) = inbound.message().await? {
            println!("bidi resp: {}", resp.message);
            bidi_count += 1;
        }
        if bidi_count == 0 {
            return Err("bidi streaming returned 0 messages".into());
        }
    }

    if !skip_cancel {
        let message_for_cancel = message.clone();
        let outbound = tokio_stream::iter((0..50).map(move |i| Payload {
            message: format!("{}-{}", message_for_cancel, i),
        }));
        let response = client.bidi_stream(Request::new(outbound)).await?;
        let mut inbound = response.into_inner();

        let mut recv_count = 0usize;
        while let Some(_resp) = inbound.message().await? {
            recv_count += 1;
            if recv_count >= cancel_after {
                drop(inbound);
                println!("bidi cancel (drop) after {} responses", recv_count);
                break;
            }
        }
    }

    if wait_goaway {
        let mut stream = client
            .server_stream(Request::new(Payload {
                message: message.clone(),
            }))
            .await?
            .into_inner();
        while let Some(_resp) = stream.message().await? {
            // wait until server shutdown
        }
        println!("goaway/close observed");
    }

    println!("interop streaming suite complete");
    Ok(())
}
