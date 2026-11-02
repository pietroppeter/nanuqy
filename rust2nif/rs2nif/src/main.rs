fn main() {
    let path = std::env::args().nth(1).expect("usage: rs2nif file.rs");
    let src = std::fs::read_to_string(&path).unwrap();
    let file = syn::parse_file(&src).unwrap();
    println!("{:#?}", file);
}
