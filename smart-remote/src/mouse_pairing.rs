//! Observe the OS bond; a GATT connection is not mouse pairing.
#[derive(Default)]
pub(crate) struct Observer {
    #[cfg(target_os = "linux")]
    connection: std::sync::Mutex<Option<dbus::blocking::Connection>>,
}

#[cfg(target_os = "linux")]
pub(crate) async fn paired(
    observer: std::sync::Arc<Observer>,
    addresses: Vec<String>,
) -> Option<bool> {
    if addresses.is_empty() {
        return None;
    }
    tokio::task::spawn_blocking(move || {
        use dbus::blocking::stdintf::org_freedesktop_dbus::ObjectManager;
        let mut cached = observer
            .connection
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if cached.is_none() {
            *cached = dbus::blocking::Connection::new_system().ok();
        }
        let connection = cached.as_ref()?;
        let proxy = connection.with_proxy("org.bluez", "/", std::time::Duration::from_secs(2));
        let devices = match proxy.get_managed_objects() {
            Ok(devices) => devices,
            Err(error) => {
                log::debug!("Mouse pairing query failed: {error}");
                *cached = None;
                return None;
            }
        };
        Some(devices.values().any(|interfaces| {
            let Some(properties) = interfaces.get("org.bluez.Device1") else {
                return false;
            };
            let address = properties.get("Address").and_then(|v| v.0.as_str());
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
            address.is_some_and(|address| {
                addresses
                    .iter()
                    .any(|saved| saved.eq_ignore_ascii_case(address))
            }) && bonded
                && hid
        }))
    })
    .await
    .ok()
    .flatten()
}

#[cfg(target_os = "windows")]
pub(crate) async fn paired(
    _observer: std::sync::Arc<Observer>,
    addresses: Vec<String>,
) -> Option<bool> {
    if addresses.is_empty() {
        return None;
    }
    use windows::Devices::{Bluetooth::BluetoothLEDevice, Enumeration::DeviceInformation};
    let read = async {
        let selector = BluetoothLEDevice::GetDeviceSelectorFromPairingState(true).ok()?;
        let devices = DeviceInformation::FindAllAsyncAqsFilter(&selector)
            .ok()?
            .await
            .ok()?;
        for index in 0..devices.Size().ok()? {
            let device = devices.GetAt(index).ok()?;
            let remote = BluetoothLEDevice::FromIdAsync(&device.Id().ok()?)
                .ok()?
                .await
                .ok()?;
            let address = format!("{:012X}", remote.BluetoothAddress().ok()?);
            let matched = addresses
                .iter()
                .any(|saved| saved.replace(':', "").eq_ignore_ascii_case(&address));
            if matched && device.Pairing().ok()?.IsPaired().ok()? {
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
pub(crate) async fn paired(
    _observer: std::sync::Arc<Observer>,
    _addresses: Vec<String>,
) -> Option<bool> {
    None
}
