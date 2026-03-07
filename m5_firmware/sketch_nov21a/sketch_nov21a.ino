#include <Arduino.h>
#include <M5Unified.h>
#include <Wire.h>
#include <SPIFFS.h>
#include <math.h>
#include <NimBLEDevice.h>

#include "MAX30105.h"
#include "heartRate.h"

// ----------------- Pins -----------------
#define SDA_PIN 32
#define SCL_PIN 33
#define I2C_HZ  100000
#define MAX_ADDR 0x57
#define HOLD_PIN 4   // M5StickC Plus2 power hold pin

// ----------------- Sensor Config -----------------
const byte LED_MODE       = 2;      // Red + IR
byte       ledBrightness  = 0xFF;   // Max power
const byte SAMPLE_AVG     = 4;
const int  SAMPLE_RATE_HZ = 100;
const int  PWIDTH_US      = 411;
const int  ADC_RANGE      = 16384;

// ----------------- Thresholds -----------------
const uint32_t IR_HARD_HIGH = 250000;
const uint32_t IR_SOFT_HIGH = 210000;
const uint32_t IR_SOFT_LOW  = 60000;
const uint32_t IR_GOOD_MIN  = 70000;
const uint32_t IR_GOOD_MAX  = 180000;
const unsigned long ADJUST_PERIOD_MS = 800;

// ----------------- Finger & Beat Limits -----------------
const uint32_t FINGER_MIN_IR        = 25000;
const unsigned long NO_BEAT_TIMEOUT_MS = 3000;
const unsigned long IBI_MIN_MS      = 300;
const unsigned long IBI_MAX_MS      = 2400;

// ----------------- Globals -----------------
MAX30105 sensor;
bool hasMAX = false;
bool imuOK  = false;

// HR tracking
const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeatMs = 0;
long lastBeatSeenMs = 0;
int  BPM = -1;
int  lastValidBpm = -1;
uint32_t lastValidBpmMs = 0;
const uint32_t HR_HOLD_MS = 5000;

// Accel & Motion
float lastAx = 0, lastAy = 0, lastAz = 0;
float motionMag = 0.0f;
const float MOTION_ALPHA = 0.15f;

// Logging & Session
bool recording = false;
File logFile;
size_t rowsWritten = 0;
uint32_t lastSendMs = 0;
uint32_t lastDrawMs = 0;
const uint32_t SAMPLE_SEND_PERIOD_MS = 100;

// ----------------- BLE Globals -----------------
static NimBLEServer* pServer = nullptr;
static NimBLECharacteristic* pTxCharacteristic = nullptr;
static bool bleConnected = false;
static bool bleAdvertising = false;

#define DEV_NAME          "M5SleepDemo"
#define NUS_SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_CHAR_TX_UUID  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // Notify
#define NUS_CHAR_RX_UUID  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // Write

// ----------------- Forward Declarations -----------------
void bleSendLine(const String& line);
void powerOffDevice();
void stopSensor();

// ----------------- Sensor Helpers -----------------
void applyConfig() {
  sensor.setup(ledBrightness, SAMPLE_AVG, LED_MODE, SAMPLE_RATE_HZ, PWIDTH_US, ADC_RANGE);
  sensor.setPulseAmplitudeRed(ledBrightness);
  sensor.setPulseAmplitudeIR(ledBrightness);
  sensor.clearFIFO();
}

void autoLevel(uint32_t ir, bool finger) {
  static unsigned long lastAdjust = 0;
  if (millis() - lastAdjust < ADJUST_PERIOD_MS) return;
  lastAdjust = millis();

  bool changed = false;
  if (ir > IR_SOFT_HIGH && ledBrightness >= 0x20) {
    ledBrightness -= 0x10;
    changed = true;
  } else if (finger && ir < IR_SOFT_LOW && ledBrightness <= 0xEF) {
    ledBrightness += 0x10;
    changed = true;
  }

  if (changed && hasMAX) applyConfig();
}

void stopSensor() {
  if (!hasMAX) return;

  // Turn LEDs off first, then put sensor in low power
  sensor.setPulseAmplitudeRed(0);
  sensor.setPulseAmplitudeIR(0);
  sensor.setPulseAmplitudeGreen(0);
  delay(10);
  sensor.shutDown();
}

void wakeSensor() {
  if (!hasMAX) return;

  sensor.wakeUp();
  delay(10);
  applyConfig();
}

// ----------------- BLE -----------------
void bleStopAdvertising() {
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  if (adv) adv->stop();
  bleAdvertising = false;
  Serial.println("[BLE] Advertising STOPPED");
}

class MyServerCallbacks : public NimBLEServerCallbacks {
public:
  void onConnect(NimBLEServer* pS, NimBLEConnInfo& connInfo) override {
    (void)pS;
    (void)connInfo;
    bleConnected = true;
    bleStopAdvertising();
    Serial.println("[BLE] CONNECTED");
    bleSendLine("CONNECTED");
  }

  void onDisconnect(NimBLEServer* pS, NimBLEConnInfo& connInfo, int reason) override {
    (void)pS;
    (void)connInfo;
    (void)reason;
    bleConnected = false;
    Serial.println("[BLE] DISCONNECTED -> restart ADV");
    NimBLEDevice::startAdvertising();
    bleAdvertising = true;
  }
};

void bleStartAdvertising() {
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->reset();
  adv->addServiceUUID(NUS_SERVICE_UUID);
  adv->start();
  bleAdvertising = true;

  Serial.print("[BLE] Advertising STARTED as: ");
  Serial.println(DEV_NAME);
}

void blePollConnectionStatus() {
  static int lastCount = -1;
  int cnt = 0;

  if (pServer) cnt = pServer->getConnectedCount();

  if (cnt != lastCount) {
    lastCount = cnt;
    bleConnected = (cnt > 0);
    bleAdvertising = !bleConnected;

    Serial.printf("[BLE] connectedCount=%d\n", cnt);

    if (bleConnected) {
      bleStopAdvertising();
    } else {
      NimBLEDevice::startAdvertising();
      bleAdvertising = true;
    }
  }
}

void bleInit() {
  Serial.println("[BLE] init...");

  NimBLEDevice::init(DEV_NAME);
  NimBLEDevice::setDeviceName(DEV_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(185);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  NimBLEService* pService = pServer->createService(NUS_SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
    NUS_CHAR_TX_UUID,
    NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ
  );
  pTxCharacteristic->createDescriptor("2902", NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);

  pService->createCharacteristic(NUS_CHAR_RX_UUID, NIMBLE_PROPERTY::WRITE);

  pService->start();
  bleStartAdvertising();
}

void bleSendLine(const String& line) {
  if (!pTxCharacteristic) return;
  if (!bleConnected) return;

  String msg = line + "\n";

  const size_t CHUNK = 20;
  const size_t L = msg.length();

  for (size_t i = 0; i < L; i += CHUNK) {
    size_t end = i + CHUNK;
    if (end > L) end = L;

    String part = msg.substring(i, end);
    pTxCharacteristic->setValue((uint8_t*)part.c_str(), part.length());
    pTxCharacteristic->notify();
    delay(8);
  }
}

void bleSendSample(uint32_t t_ms, int hr_bpm, float ax, float ay, float az) {
  String line =
    String(t_ms) + "," +
    String(hr_bpm) + "," +
    String(ax, 5) + "," +
    String(ay, 5) + "," +
    String(az, 5);
  bleSendLine(line);
}

// ----------------- UI -----------------
void drawOverlay(uint32_t ir, float ax, float ay, float az) {
  if (millis() - lastDrawMs < 100) return;
  lastDrawMs = millis();

  M5.Display.startWrite();
  M5.Display.fillScreen(TFT_BLACK);

  // Finger status
  M5.Display.fillCircle(8, 8, 5, (ir >= FINGER_MIN_IR) ? TFT_GREEN : TFT_RED);

  if (recording) {
    M5.Display.fillRoundRect(M5.Display.width() - 42, 4, 38, 14, 4, TFT_RED);
    M5.Display.setTextColor(TFT_WHITE);
    M5.Display.setCursor(M5.Display.width() - 36, 7);
    M5.Display.print("REC");
  }

  // HR display
  int hrDisp = (BPM > 0) ? BPM : ((millis() - lastValidBpmMs < HR_HOLD_MS) ? lastValidBpm : -1);

  M5.Display.setTextColor(TFT_YELLOW);
  M5.Display.setTextSize(2);
  M5.Display.setCursor(6, 30);
  if (hrDisp > 0) {
    M5.Display.printf("HR: %d", hrDisp);
  } else {
    M5.Display.print("HR: --");
  }

  // Accelerometer
  M5.Display.setTextColor(TFT_WHITE);
  M5.Display.setTextSize(1);
  M5.Display.setCursor(6, 65);  M5.Display.printf("AX: % .3f", ax);
  M5.Display.setCursor(6, 77);  M5.Display.printf("AY: % .3f", ay);
  M5.Display.setCursor(6, 89);  M5.Display.printf("AZ: % .3f", az);

  M5.Display.setTextColor(TFT_CYAN);
  M5.Display.setCursor(6, 110);
  M5.Display.printf("Rows: %lu", (unsigned long)rowsWritten);

  M5.Display.setTextColor(TFT_GREEN);
  M5.Display.setCursor(6, 125);
  M5.Display.print("A=REC  Bx2=OFF");

  M5.Display.endWrite();
}

// ----------------- Logging -----------------
void startRecording() {
  if (recording) return;

  logFile = SPIFFS.open("/sleep_raw.csv", FILE_WRITE);
  if (!logFile) {
    Serial.println("[FILE] Failed to open /sleep_raw.csv");
    return;
  }

  if (logFile.size() == 0) {
    logFile.println("timestamp_ms,hr_bpm,acc_x,acc_y,acc_z");
  }

  recording = true;
  rowsWritten = 0;
  Serial.println("[REC] START");
}

void stopRecording() {
  if (!recording) return;

  if (logFile) {
    logFile.flush();
    logFile.close();
  }

  recording = false;
  Serial.println("[REC] STOP");
}

// ----------------- Power Off -----------------
void powerOffDevice() {
  Serial.println("[PWR] Powering off...");

  stopRecording();
  stopSensor();

  if (bleConnected && pTxCharacteristic) {
    bleSendLine("POWERING_OFF");
    delay(20);
  }

  bleStopAdvertising();

  M5.Display.fillScreen(TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE);
  M5.Display.setTextSize(2);
  M5.Display.setCursor(20, 50);
  M5.Display.print("Power off");
  delay(150);

  // Real power-off request on StickC Plus2
  digitalWrite(HOLD_PIN, LOW);

  while (true) {
    delay(1000);
  }
}

// ----------------- Setup -----------------
void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setRotation(3);
  Serial.begin(115200);

  // Keep power held after wake on StickC Plus2
  pinMode(HOLD_PIN, OUTPUT);
  digitalWrite(HOLD_PIN, HIGH);

  if (!SPIFFS.begin(true)) {
    Serial.println("[SPIFFS] mount failed");
  }

  imuOK = M5.Imu.begin();

  Wire.begin(SDA_PIN, SCL_PIN, I2C_HZ);

  if (sensor.begin(Wire, I2C_HZ, MAX_ADDR)) {
    hasMAX = true;
    applyConfig();
    Serial.println("[MAX3010x] OK");
  } else {
    hasMAX = false;
    Serial.println("[MAX3010x] NOT FOUND");
  }

  bleInit();
}

// ----------------- Loop -----------------
void loop() {
  M5.update();
  blePollConnectionStatus();

  // Button A = start/stop recording
  if (M5.BtnA.wasClicked()) {
    if (!recording) startRecording();
    else stopRecording();
  }

  // Button B double click = controlled shutdown
  if (M5.BtnB.wasDoubleClicked()) {
    powerOffDevice();
  }

  // Accel data
  float ax = 0, ay = 0, az = 0;
  if (imuOK) {
    M5.Imu.getAccel(&ax, &ay, &az);
  }

  // Motion magnitude
  float dAx = ax - lastAx;
  float dAy = ay - lastAy;
  float dAz = az - lastAz;
  float deltaMag = sqrtf(dAx * dAx + dAy * dAy + dAz * dAz);
  motionMag = MOTION_ALPHA * deltaMag + (1.0f - MOTION_ALPHA) * motionMag;
  lastAx = ax;
  lastAy = ay;
  lastAz = az;

  // Sensor data
  uint32_t ir = 0;
  if (hasMAX) {
    sensor.check();
    ir = sensor.getIR();
    autoLevel(ir, (ir > FINGER_MIN_IR));
  }

  // Heart rate processing
  if (hasMAX && ir > FINGER_MIN_IR && checkForBeat(ir)) {
    unsigned long now = millis();
    long delta = now - lastBeatMs;

    if (delta > IBI_MIN_MS && delta < IBI_MAX_MS) {
      BPM = 60000 / delta;
      lastValidBpm = BPM;
      lastValidBpmMs = now;
      lastBeatSeenMs = now;
    }

    lastBeatMs = now;
  }

  if (millis() - lastBeatSeenMs > NO_BEAT_TIMEOUT_MS) {
    BPM = -1;
  }

  // Logging + BLE
  if (recording && (millis() - lastSendMs >= SAMPLE_SEND_PERIOD_MS)) {
    lastSendMs = millis();

    int hrOut = (BPM > 0) ? BPM : ((millis() - lastValidBpmMs < HR_HOLD_MS) ? lastValidBpm : -1);

    if (logFile) {
      logFile.printf("%lu,%d,%.5f,%.5f,%.5f\n", lastSendMs, hrOut, ax, ay, az);
      logFile.flush();
      rowsWritten++;
    }

    if (bleConnected) {
      bleSendSample(lastSendMs, hrOut, ax, ay, az);
    }
  }

  drawOverlay(ir, ax, ay, az);
  delay(10);
}