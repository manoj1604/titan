use serde_json::json;

pub fn platform() -> String {
    format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)
}

pub fn fib(n: u64) -> u64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn main() {
    println!("{}", json!({ "ok": true, "platform": platform(), "fib20": fib(20) }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_on_linux() { assert_eq!(platform(), "linux aarch64"); }

    #[test]
    fn fib_works() { assert_eq!(fib(20), 6765); }
}
