const DEFAULT_SETTINGS = {
  service: "180D",
  heel: "A001",
  left: "A002",
  right: "A003",
  cadence: "A004",
  batteryService: "180F",
  battery: "2A19",
  encoding: "uint16",
  forceScale: ""
};

const SETTINGS_KEY = "smart-shoe-web.settings.v1";
const DEVICE_KEY = "smart-shoe-web.device-id.v1";
const $ = (selector) => document.querySelector(selector);

const ui = {
  connect: $("#connectButton"),
  settings: $("#settingsButton"),
  settingsDialog: $("#settingsDialog"),
  settingsForm: $("#settingsForm"),
  closeSettings: $("#closeSettings"),
  closeSettingsSecondary: $("#closeSettingsSecondary"),
  formError: $("#formError"),
  message: $("#connectionMessage"),
  state: $("#connectionState"),
  dot: $("#connectionDot"),
  deviceName: $("#deviceName"),
  cadence: $("#cadenceValue"),
  impact: $("#impactValue"),
  impactUnit: $("#impactUnit"),
  impactCaption: $("#impactCaption"),
  battery: $("#batteryValue"),
  batteryIcon: $("#batteryIcon"),
  activity: $("#activityLabel"),
  demo: $("#demoButton"),
  demoText: $("#demoButtonText"),
  browserNotice: $("#browserNotice")
};

let settings = loadSettings();
let connectionState = "disconnected";
let currentDevice = null;
let currentServer = null;
let reconnectEnabled = false;
let reconnectTimer = null;
let demoTimer = null;
let demoEnabled = false;
let connectionAttempt = 0;
let values = { heel: 0, left: 0, right: 0, cadence: null, battery: null };

function loadSettings() {
  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}") };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function bluetoothUUID(value, type) {
  const trimmed = value.trim();
  const shortUUID = /^(?:0x)?([0-9a-f]{4}|[0-9a-f]{8})$/i.exec(trimmed);
  if (shortUUID) {
    const number = Number.parseInt(shortUUID[1], 16);
    return type === "service"
      ? BluetoothUUID.getService(number)
      : BluetoothUUID.getCharacteristic(number);
  }
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trimmed)) {
    return trimmed.toLowerCase();
  }
  throw new Error(`Enter a valid ${type} UUID.`);
}

function setConnectionState(state, message) {
  connectionState = state;
  ui.state.textContent = state === "scanning" ? "Connecting" : state;
  ui.dot.dataset.state = state;
  ui.message.textContent = message;
  ui.connect.disabled = !navigator.bluetooth || !window.isSecureContext;
  ui.connect.classList.toggle("is-connected", state === "connected");
  ui.connectText.textContent = state === "connected"
    ? "Disconnect"
    : state === "scanning"
      ? "Cancel connection"
      : "Connect shoe";
  ui.connectIcon = setDynamicIcon(
    ui.connectIcon,
    state === "connected" ? "bluetooth-off" : "bluetooth"
  );
}

function refreshIcons() {
  if (window.lucide) window.lucide.createIcons();
}

function setDynamicIcon(current, name) {
  if (current.dataset.iconName === name) return current;
  const replacement = document.createElement("i");
  replacement.id = current.id;
  replacement.className = [...current.classList]
    .filter((className) => className !== "lucide" && !className.startsWith("lucide-"))
    .join(" ");
  replacement.dataset.iconName = name;
  replacement.dataset.lucide = name;
  current.replaceWith(replacement);
  refreshIcons();
  return replacement;
}

function pressureColor(value) {
  const pressure = Math.min(1, Math.max(0, value));
  const low = [48, 190, 104];
  const middle = [246, 211, 57];
  const high = [232, 71, 63];
  const start = pressure < 0.5 ? low : middle;
  const end = pressure < 0.5 ? middle : high;
  const mix = pressure < 0.5 ? pressure * 2 : (pressure - 0.5) * 2;
  const channels = start.map((channel, index) => Math.round(channel + (end[index] - channel) * mix));
  return `rgb(${channels.join(",")})`;
}

function updateHeatZone(name, value) {
  const pressure = Math.min(1, Math.max(0, value));
  const gradient = $(`#${name}Gradient`);
  const color = pressureColor(pressure);
  gradient.querySelector(".heat-core").setAttribute("stop-color", color);
  gradient.querySelector(".heat-core").setAttribute("stop-opacity", (0.15 + pressure * 0.8).toFixed(2));
  gradient.querySelector(".heat-mid").setAttribute("stop-color", color);
  gradient.querySelector(".heat-glow").setAttribute("stop-color", color);
  gradient.querySelector(".heat-mid").setAttribute("stop-opacity", (0.26 + pressure * 0.4).toFixed(2));
  gradient.querySelector(".heat-glow").setAttribute("stop-opacity", (0.08 + pressure * 0.24).toFixed(2));
  $(`#${name}Percent`).textContent = `${Math.round(pressure * 100)}%`;
  $(`#${name}Value`).setAttribute("fill", color);
}

function renderTelemetry() {
  updateHeatZone("heel", values.heel);
  updateHeatZone("left", values.left);
  updateHeatZone("right", values.right);

  const pressures = [values.heel, values.left, values.right];
  const relativeLoad = pressures.reduce((sum, value) => sum + value, 0) / pressures.length;
  const forceScale = Number.parseFloat(settings.forceScale);
  if (Number.isFinite(forceScale) && forceScale > 0) {
    const force = pressures.reduce((sum, value) => sum + value * forceScale, 0);
    ui.impact.textContent = `${Math.round(force)}`;
    ui.impactUnit.textContent = "N";
    ui.impactCaption.textContent = "Calibrated estimate";
  } else {
    ui.impact.textContent = `${Math.round(relativeLoad * 100)}`;
    ui.impactUnit.textContent = "%";
    ui.impactCaption.textContent = "Relative load";
  }

  ui.cadence.textContent = values.cadence === null ? "--" : `${Math.round(values.cadence)}`;
  ui.battery.textContent = values.battery === null ? "--" : `${values.battery}%`;
  ui.batteryIcon = setDynamicIcon(ui.batteryIcon, batteryIcon(values.battery));
  ui.activity.textContent = values.cadence === null ? "Waiting for sensor data" : "Live sensor feed";
}

function batteryIcon(level) {
  if (level === null) return "battery-warning";
  if (level >= 75) return "battery-full";
  if (level >= 50) return "battery-medium";
  if (level >= 20) return "battery-low";
  return "battery-warning";
}

function decodePressure(dataView) {
  switch (settings.encoding) {
    case "uint8":
      return dataView.byteLength >= 1 ? dataView.getUint8(0) / 255 : null;
    case "float32": {
      if (dataView.byteLength < 4) return null;
      const value = dataView.getFloat32(0, true);
      return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : null;
    }
    default:
      return dataView.byteLength >= 2 ? dataView.getUint16(0, true) / 65535 : null;
  }
}

function decodeCadence(dataView) {
  if (dataView.byteLength >= 2) return dataView.getUint16(0, true);
  return dataView.byteLength >= 1 ? dataView.getUint8(0) : null;
}

function bindCharacteristic(characteristic, type) {
  const notificationHandler = (event) => {
    const data = event.target.value;
    if (type === "heel" || type === "left" || type === "right") {
      const decoded = decodePressure(data);
      if (decoded !== null) values[type] = decoded;
    } else if (type === "cadence") {
      values.cadence = decodeCadence(data);
    } else if (type === "battery") {
      if (data.byteLength < 1) return;
      const level = data.getUint8(0);
      if (level <= 100) values.battery = level;
    }
    renderTelemetry();
  };
  characteristic.addEventListener("characteristicvaluechanged", notificationHandler);
  if (characteristic.properties.notify || characteristic.properties.indicate) {
    return characteristic.startNotifications();
  }
  return characteristic.readValue();
}

async function attachSensor(service, uuid, type, optional = false) {
  if (!uuid) return false;
  try {
    const characteristic = await service.getCharacteristic(uuid);
    await bindCharacteristic(characteristic, type);
    return true;
  } catch (error) {
    if (!optional) console.warn(`Could not set up ${type} sensor`, error);
    return false;
  }
}

async function connectDevice(device, attempt = connectionAttempt) {
  clearTimeout(reconnectTimer);
  setConnectionState("scanning", `Connecting to ${device.name || "shoe sensor"}...`);
  currentDevice = device;
  device.removeEventListener("gattserverdisconnected", onDisconnected);
  device.addEventListener("gattserverdisconnected", onDisconnected);

  try {
    const config = getUUIDSettings();
    currentServer = await device.gatt.connect();
    if (attempt !== connectionAttempt) {
      device.gatt.disconnect();
      return;
    }
    const shoeService = await currentServer.getPrimaryService(config.service);
    if (attempt !== connectionAttempt) {
      device.gatt.disconnect();
      return;
    }
    const results = await Promise.all([
      attachSensor(shoeService, config.heel, "heel"),
      attachSensor(shoeService, config.left, "left"),
      attachSensor(shoeService, config.right, "right"),
      attachSensor(shoeService, config.cadence, "cadence", true)
    ]);

    try {
      const batteryService = await currentServer.getPrimaryService(config.batteryService);
      await attachSensor(batteryService, config.battery, "battery", true);
    } catch {
      await attachSensor(shoeService, config.battery, "battery", true);
    }

    try { localStorage.setItem(DEVICE_KEY, device.id); } catch { /* Storage can be unavailable. */ }
    reconnectEnabled = true;
    const active = results.slice(0, 3).filter(Boolean).length;
    setConnectionState("connected", `${device.name || "Shoe sensor"} connected - ${active}/3 pressure sensors active`);
    ui.deviceName.textContent = device.name || "BLE shoe sensor";
    renderTelemetry();
  } catch (error) {
    if (attempt !== connectionAttempt) return;
    if (device.gatt?.connected) device.gatt.disconnect();
    currentServer = null;
    currentDevice = null;
    setConnectionState("disconnected", errorMessage(error));
  }
}

function onDisconnected() {
  currentServer = null;
  values = { heel: 0, left: 0, right: 0, cadence: null, battery: null };
  renderTelemetry();
  if (reconnectEnabled && currentDevice && navigator.bluetooth) {
    setConnectionState("scanning", "Connection lost. Reconnecting...");
    reconnectTimer = window.setTimeout(() => {
      if (reconnectEnabled && currentDevice) void connectDevice(currentDevice);
    }, 1800);
  } else {
    setConnectionState("disconnected", "Shoe disconnected");
  }
}

function errorMessage(error) {
  if (error?.name === "NotFoundError") return "No shoe selected. Choose a device to connect.";
  if (error?.name === "SecurityError") return "Bluetooth permission is blocked for this site.";
  if (error?.name === "NotSupportedError") return "This browser or shoe does not support the requested BLE service.";
  if (error?.name === "NetworkError") return "Could not connect. Move closer to the shoe and try again.";
  return error?.message || "Bluetooth connection failed. Check the UUID settings and try again.";
}

function getUUIDSettings() {
  return {
    service: bluetoothUUID(settings.service, "service"),
    heel: bluetoothUUID(settings.heel, "characteristic"),
    left: bluetoothUUID(settings.left, "characteristic"),
    right: bluetoothUUID(settings.right, "characteristic"),
    cadence: settings.cadence.trim() ? bluetoothUUID(settings.cadence, "characteristic") : null,
    batteryService: bluetoothUUID(settings.batteryService, "service"),
    battery: bluetoothUUID(settings.battery, "characteristic")
  };
}

async function handleConnectClick() {
  if (connectionState === "connected") {
    connectionAttempt += 1;
    reconnectEnabled = false;
    clearTimeout(reconnectTimer);
    if (currentDevice?.gatt?.connected) currentDevice.gatt.disconnect();
    currentServer = null;
    currentDevice = null;
    values = { heel: 0, left: 0, right: 0, cadence: null, battery: null };
    renderTelemetry();
    setConnectionState("disconnected", "Disconnected");
    return;
  }

  if (connectionState === "scanning") {
    connectionAttempt += 1;
    reconnectEnabled = false;
    clearTimeout(reconnectTimer);
    currentDevice?.gatt?.disconnect();
    currentDevice = null;
    currentServer = null;
    setConnectionState("disconnected", "Connection cancelled");
    return;
  }

  const attempt = ++connectionAttempt;
  try {
    const config = getUUIDSettings();
    setConnectionState("scanning", "Choose your shoe in the browser picker...");
    const device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [config.service] }],
      optionalServices: [config.service, config.batteryService]
    });
    if (attempt !== connectionAttempt) return;
    await connectDevice(device, attempt);
  } catch (error) {
    if (attempt === connectionAttempt) setConnectionState("disconnected", errorMessage(error));
  }
}

async function tryReconnectAuthorizedDevice() {
  if (!navigator.bluetooth?.getDevices) return;
  try {
    const savedId = localStorage.getItem(DEVICE_KEY);
    if (!savedId) return;
    const devices = await navigator.bluetooth.getDevices();
    const device = devices.find((candidate) => candidate.id === savedId);
    if (!device) return;
    reconnectEnabled = true;
    await connectDevice(device);
  } catch (error) {
    console.info("Automatic reconnect is waiting for user permission", error);
  }
}

function startDemo() {
  if (demoEnabled) {
    demoEnabled = false;
    clearInterval(demoTimer);
    ui.demoText.textContent = "Preview data";
    ui.demo.setAttribute("aria-pressed", "false");
    ui.activity.textContent = connectionState === "connected" ? "Live sensor feed" : "Waiting for sensor data";
    return;
  }
  demoEnabled = true;
  ui.demoText.textContent = "Stop preview";
  ui.demo.setAttribute("aria-pressed", "true");
  let tick = 0;
  demoTimer = window.setInterval(() => {
    tick += 0.12;
    values.heel = 0.35 + Math.sin(tick) * 0.25;
    values.left = 0.2 + Math.max(0, Math.sin(tick + 0.9)) * 0.62;
    values.right = 0.16 + Math.max(0, Math.sin(tick - 0.5)) * 0.58;
    values.cadence = 112 + Math.round(Math.sin(tick * 0.5) * 8);
    values.battery = 86;
    renderTelemetry();
  }, 90);
}

function populateSettingsForm() {
  for (const [key, value] of Object.entries(settings)) {
    const input = $(`#setting-${key}`);
    if (input) input.value = value;
  }
}

function updateBrowserNotice() {
  if (!window.isSecureContext) {
    ui.browserNotice.hidden = false;
    ui.browserNotice.textContent = "Bluetooth requires a secure HTTPS connection (or localhost).";
  } else if (!navigator.bluetooth) {
    ui.browserNotice.hidden = false;
    ui.browserNotice.textContent = "Web Bluetooth is unavailable here. Open this page in Chrome or another supported Chromium browser.";
  }
  ui.connect.disabled = !navigator.bluetooth || !window.isSecureContext;
}

ui.connectText = $("#connectButtonText");
ui.connect.addEventListener("click", handleConnectClick);
ui.demo.addEventListener("click", startDemo);
ui.settings.addEventListener("click", () => {
  populateSettingsForm();
  ui.settingsDialog.showModal();
});
ui.closeSettings.addEventListener("click", () => ui.settingsDialog.close());
ui.closeSettingsSecondary.addEventListener("click", () => ui.settingsDialog.close());
ui.settingsForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const formData = new FormData(ui.settingsForm);
  const next = Object.fromEntries(formData.entries());
  try {
    const previous = settings;
    settings = { ...DEFAULT_SETTINGS, ...next };
    getUUIDSettings();
    if (!settings.forceScale.trim() || (Number.isFinite(Number(settings.forceScale)) && Number(settings.forceScale) > 0)) {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
      ui.formError.textContent = "";
      ui.settingsDialog.close();
      if (currentDevice?.gatt?.connected) handleConnectClick();
      renderTelemetry();
    } else {
      settings = previous;
      throw new Error("Force scale must be a positive number or left blank.");
    }
  } catch (error) {
    ui.formError.textContent = error.message;
  }
});

updateBrowserNotice();
populateSettingsForm();
renderTelemetry();
setConnectionState("disconnected", "Ready to connect");
void tryReconnectAuthorizedDevice();
refreshIcons();