use fixture::Fixture;

mod client;
mod fixture;
mod server;
mod test_input_backend;

#[cfg(target_os = "linux")]
mod animations;
mod binds;
mod floating;
mod fullscreen;
mod layer_shell;
mod remove_output;
mod transactions;
mod virtual_pointer;
mod window_opening;
