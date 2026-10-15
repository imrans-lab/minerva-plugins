//! Observe the OS bond; a GATT connection is not mouse pairing.
#[cfg(any(target_os = "linux", target_os = "windows"))]
const NAME: &str = "Smart Remote V2";

#[cfg(target_os = "linux")]
pub(crate) async fn paired() -> Option<bool> {
    tokio::task::spawn_blocking(|| {
        use dbus::blocking::stdintf::org_freedesktop_dbus::ObjectManager;
        let connection = dbus::blocking::Connection::new_system().ok()?;
        let proxy = connection.with_proxy("org.bluez", "/", std::time::Duration::from_secs(2));
        let devices = proxy.get_managed_objects().ok()?;
        Some(devices.values().any(|interfaces| {
            let Some(properties) = interfaces.get("org.bluez.Device1") else {
                return false;
            };
            let name = properties.get("Name").and_then(|v| v.0.as_str());
            let bonded = properties
                .get("Bonded")
                .or_else(|| properties.get("Paired"))
                .and_then(|v| v.0.as_i64())
                .unwrap_or(0)
                != 0;
            let hid = properties
                .get("UUIDs")
                .and_then(|v| v.0.as_iter())
                .is_some_and(|mut values| {
                    values.any(|v| v.as_str() == Some("00001812-0000-1000-8000-00805f9b34fb"))
                });
            name == Some(NAME) && bonded && hid
        }))
    })
    .await
    .ok()
    .flatten()
}

#[cfg(target_os = "windows")]
pub(crate) async fn paired() -> Option<bool> {
    use windows::Devices::{Bluetooth::BluetoothLEDevice, Enumeration::DeviceInformation};
    let read = async {
        let selector = BluetoothLEDevice::GetDeviceSelectorFromPairingState(true).ok()?;
        let devices = DeviceInformation::FindAllAsyncAqsFilter(&selector)
            .ok()?
            .await
            .ok()?;
        for index in 0..devices.Size().ok()? {
            let device = devices.GetAt(index).ok()?;
            if device.Name().ok()?.to_string() == NAME && device.Pairing().ok()?.IsPaired().ok()? {
                return Some(true);
            }
        }
        Some(false)
    };
    tokio::time::timeout(std::time::Duration::from_secs(3), read)
        .await
        .ok()
        .flatten()
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub(crate) async fn paired() -> Option<bool> {
    None
}
