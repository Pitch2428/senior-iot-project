#include <Arduino.h>
#include <M5Unified.h>
#include <Wire.h>
#include <SPIFFS.h>
#include <NimBLEDevice.h>
#include <esp_system.h>
#include <math.h>

#include "MAX30105.h"
#include "heartRate.h"

// ----------------- Build Options -----------------
#define ENABLE_FILE_LOG 1

// ----------------- Pins -----------------
static constexpr int SDA_PIN = 32;
static constexpr int SCL_PIN = 33;
static constexpr uint32_t I2C_HZ = 100000;
static constexpr uint8_t MAX_ADDR = 0x57;
static constexpr int HOLD_PIN = 4;

// ----------------- BLE -----------------
static constexpr char DEV_NAME[]         = "M5SleepDemo";
static constexpr char NUS_SERVICE_UUID[] = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static constexpr char NUS_CHAR_TX_UUID[] = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
static constexpr char NUS_CHAR_RX_UUID[] = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";

// ----------------- Sensor Config -----------------
static constexpr uint8_t LED_MODE       = 2;      // Red + IR
static constexpr uint8_t SAMPLE_AVG     = 4;
static constexpr int SAMPLE_RATE_HZ     = 100;
static constexpr int PWIDTH_US          = 411;
static constexpr int ADC_RANGE          = 16384;

// ----------------- Timing -----------------
static constexpr uint32_t SEND_PERIOD_MS       = 250;    // 4 Hz: lighter and enough for logging
static constexpr uint32_t DRAW_PERIOD_IDLE_MS  = 500;
static constexpr uint32_t DRAW_PERIOD_REC_MS   = 2000;
static constexpr uint32_t HEARTBEAT_PERIOD_MS  = 60000;
static constexpr uint32_t FILE_FLUSH_PERIOD_MS = 15000;

// ----------------- HR / Finger -----------------
static constexpr uint32_t FINGER_MIN_IR      = 25000;
static constexpr uint32_t NO_BEAT_TIMEOUT_MS = 3000;
static constexpr uint32_t IBI_MIN_MS         = 300;
static constexpr uint32_t IBI_MAX_MS         = 2400;
static constexpr uint32_t HR_HOLD_MS         = 5000;

// ----------------- Auto LED -----------------
static constexpr uint32_t IR_SOFT_HIGH       = 210000;
static constexpr uint32_t IR_SOFT_LOW        = 60000;
static constexpr uint32_t ADJUST_PERIOD_MS   = 800;

// ----------------- Motion -----------------
static constexpr float MOTION_ALPHA = 0.15f;

// ----------------- Globals -----------------
MAX30105 gSensor;
bool gHasMAX = false;
bool gImuOK = false;

NimBLEServer* gServer = nullptr;
NimBLECharacteristic* gTxChr = nullptr;
volatile bool gBleConnected = false;

bool gRecording = false;
bool gFileWriteError = false;

#if ENABLE_FILE_LOG
File gLogFile;
#endif

uint32_t gLastSendMs = 0;
uint32_t gLastDrawMs = 0;
uint32_t gLastHeartbeatMs = 0;
uint32_t gLastFlushMs = 0;

size_t gRowsWritten = 0;

int gBPM = -1;
int gLastValidBpm = -1;
uint32_t gLastBeatMs = 0;
uint32_t gLastBeatSeenMs = 0;
uint32_t gLastValidBpmMs = 0;

float gLastAx = 0.0f;
float gLastAy = 0.0f;
float gLastAz = 0.0f;
float gMotionMag = 0.0f;

uint8_t gLedBrightness = 0xFF;

// ----------------- Helpers -----------------
static inline int currentHrOut() {
  if (gBPM > 0) return gBPM;
  if (millis() - gLastValidBpmMs < HR_HOLD_MS) return gLastValidBpm;
  return -1;
}

void applySensorConfig() {
  gSensor.setup(gLedBrightness, SAMPLE_AVG, LED_MODE, SAMPLE_RATE_HZ, PWIDTH_US, ADC_RANGE);
  gSensor.setPulseAmplitudeRed(gLedBrightness);
  gSensor.setPulseAmplitudeIR(gLedBrightness);
  gSensor.clearFIFO();
}

void autoLevel(uint32_t ir, bool fingerPresent) {
  static uint32_t lastAdjustMs = 0;
  const uint32_t now = millis();
  if (now - lastAdjustMs < ADJUST_PERIOD_MS) return;
  lastAdjustMs = now;

  uint8_t next = gLedBrightness;

  if (ir > IR_SOFT_HIGH && next >= 0x20) {
    next = uint8_t(next - 0x10);
  } else if (fingerPresent && ir < IR_SOFT_LOW && next <= 0xEF) {
    next = uint8_t(next + 0x10);
  }

  if (next != gLedBrightness) {
    gLedBrightness = next;
    if (gHasMAX) applySensorConfig();
  }
}

void stopSensor() {
  if (!gHasMAX) return;
  gSensor.setPulseAmplitudeRed(0);
  gSensor.setPulseAmplitudeIR(0);
  gSensor.setPulseAmplitudeGreen(0);
  delay(10);
  gSensor.shutDown();
}

void powerOffDevice() {
  Serial.println("[PWR] Powering off");

#if ENABLE_FILE_LOG
  if (gRecording && gLogFile) {
    gLogFile.flush();
    gLogFile.close();
  }
#endif

  gRecording = false;
  stopSensor();

  if (gBleConnected && gTxChr) {
    const char offMsg[] = "POWERING_OFF\n";
    gTxChr->setValue((const uint8_t*)offMsg, sizeof(offMsg) - 1);
    gTxChr->notify();
    delay(20);
  }

  NimBLEDevice::stopAdvertising();

  M5.Display.fillScreen(TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE);
  M5.Display.setTextSize(2);
  M5.Display.setCursor(18, 50);
  M5.Display.print("Power off");
  delay(150);

  digitalWrite(HOLD_PIN, LOW);
  while (true) delay(1000);
}

// ----------------- BLE -----------------
class ServerCallbacks : public NimBLEServerCallbacks {
public:
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
    gBleConnected = true;
    NimBLEDevice::stopAdvertising();
    Serial.println("[BLE] CONNECTED");
  }

  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
    gBleConnected = false;
    Serial.printf("[BLE] DISCONNECTED reason=%d\n", reason);
    NimBLEDevice::startAdvertising();
  }
};

void bleInit() {
  NimBLEDevice::init(DEV_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(185);

  gServer = NimBLEDevice::createServer();
  gServer->setCallbacks(new ServerCallbacks());

  NimBLEService* svc = gServer->createService(NUS_SERVICE_UUID);

  gTxChr = svc->createCharacteristic(
    NUS_CHAR_TX_UUID,
    NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ
  );
  gTxChr->createDescriptor("2902", NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);

  svc->createCharacteristic(NUS_CHAR_RX_UUID, NIMBLE_PROPERTY::WRITE);
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE_UUID);
  adv->start();

  Serial.println("[BLE] Advertising started");
}

void bleSendSample(uint32_t tMs, int hr, float ax, float ay, float az) {
  if (!gBleConnected || !gTxChr) return;

  char line[96];
  const int n = snprintf(
    line,
    sizeof(line),
    "%lu,%d,%.5f,%.5f,%.5f\n",
    (unsigned long)tMs,
    hr,
    ax,
    ay,
    az
  );

  if (n <= 0) return;

  gTxChr->setValue((const uint8_t*)line, (size_t)n);
  if (!gTxChr->notify()) {
    Serial.println("[BLE] notify failed");
  }
}

// ----------------- File Logging -----------------
void flushLogNow() {
#if ENABLE_FILE_LOG
  if (gLogFile) {
    gLogFile.flush();
    gLastFlushMs = millis();
  }
#endif
}

void startRecording() {
  if (gRecording) return;

#if ENABLE_FILE_LOG
  gLogFile = SPIFFS.open("/sleep_raw.csv", FILE_APPEND);
  if (!gLogFile) {
    Serial.println("[FILE] open failed");
    gFileWriteError = true;
    return;
  }

  if (gLogFile.size() == 0) {
    gLogFile.println("timestamp_ms,hr_bpm,acc_x,acc_y,acc_z");
    gLogFile.flush();
  }
#endif

  gRowsWritten = 0;
  gFileWriteError = false;
  gLastSendMs = millis();
  gLastFlushMs = millis();
  gLastHeartbeatMs = millis();
  gRecording = true;

  Serial.println("[REC] START");
}

void stopRecording() {
  if (!gRecording) return;

#if ENABLE_FILE_LOG
  flushLogNow();
  if (gLogFile) gLogFile.close();
#endif

  gRecording = false;
  Serial.println("[REC] STOP");
}

void appendSampleToFile(uint32_t tMs, int hr, float ax, float ay, float az) {
#if ENABLE_FILE_LOG
  if (!gLogFile) return;

  const int written = gLogFile.printf(
    "%lu,%d,%.5f,%.5f,%.5f\n",
    (unsigned long)tMs,
    hr,
    ax,
    ay,
    az
  );

  if (written <= 0) {
    gFileWriteError = true;
    Serial.println("[FILE] write failed");
    return;
  }

  if (millis() - gLastFlushMs >= FILE_FLUSH_PERIOD_MS) {
    flushLogNow();
  }
#else
  (void)tMs; (void)hr; (void)ax; (void)ay; (void)az;
#endif
}

// ----------------- UI -----------------
void drawOverlay(uint32_t ir, float ax, float ay, float az) {
  const uint32_t now = millis();
  const uint32_t period = gRecording ? DRAW_PERIOD_REC_MS : DRAW_PERIOD_IDLE_MS;
  if (now - gLastDrawMs < period) return;
  gLastDrawMs = now;

  M5.Display.startWrite();
  M5.Display.fillScreen(TFT_BLACK);

  M5.Display.fillCircle(8, 8, 5, (ir >= FINGER_MIN_IR) ? TFT_GREEN : TFT_RED);

  if (gRecording) {
    M5.Display.fillRoundRect(M5.Display.width() - 42, 4, 38, 14, 4, TFT_RED);
    M5.Display.setTextColor(TFT_WHITE);
    M5.Display.setCursor(M5.Display.width() - 36, 7);
    M5.Display.print("REC");
  }

  M5.Display.setTextColor(TFT_YELLOW);
  M5.Display.setTextSize(2);
  M5.Display.setCursor(6, 24);
  const int hrDisp = currentHrOut();
  if (hrDisp > 0) M5.Display.printf("HR: %d", hrDisp);
  else M5.Display.print("HR: --");

  M5.Display.setTextColor(TFT_CYAN);
  M5.Display.setTextSize(1);
  M5.Display.setCursor(6, 54);
  M5.Display.printf("Rows: %lu", (unsigned long)gRowsWritten);

  M5.Display.setCursor(6, 68);
  M5.Display.printf("BLE: %s", gBleConnected ? "YES" : "NO");

  M5.Display.setCursor(6, 82);
  M5.Display.printf("Heap: %u", (unsigned int)ESP.getFreeHeap());

  M5.Display.setCursor(6, 96);
  M5.Display.printf("Motion: %.4f", gMotionMag);

  if (!gRecording) {
    M5.Display.setTextColor(TFT_WHITE);
    M5.Display.setCursor(6, 112); M5.Display.printf("AX: % .3f", ax);
    M5.Display.setCursor(6, 124); M5.Display.printf("AY: % .3f", ay);
    M5.Display.setCursor(6, 136); M5.Display.printf("AZ: % .3f", az);
  } else {
    M5.Display.setTextColor(gFileWriteError ? TFT_RED : TFT_GREEN);
    M5.Display.setCursor(6, 124);
    M5.Display.print(gFileWriteError ? "FILE ERR" : "RUNNING");
  }

  M5.Display.endWrite();
}

// ----------------- Diagnostics -----------------
void printHeartbeat(uint32_t ir) {
  const uint32_t now = millis();
  if (now - gLastHeartbeatMs < HEARTBEAT_PERIOD_MS) return;
  gLastHeartbeatMs = now;

  Serial.printf(
    "[HB] up=%lu rec=%d rows=%lu heap=%u ble=%d ir=%lu hr=%d motion=%.5f\n",
    (unsigned long)now,
    gRecording ? 1 : 0,
    (unsigned long)gRowsWritten,
    (unsigned int)ESP.getFreeHeap(),
    gBleConnected ? 1 : 0,
    (unsigned long)ir,
    gBPM,
    gMotionMag
  );

  if (gRecording) flushLogNow();
}

// ----------------- Setup / Loop -----------------
void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setRotation(3);

  Serial.begin(115200);
  delay(100);

  Serial.printf("[BOOT] reset_reason=%d\n", (int)esp_reset_reason());
  Serial.printf("[BOOT] free_heap=%u\n", (unsigned int)ESP.getFreeHeap());

  pinMode(HOLD_PIN, OUTPUT);
  digitalWrite(HOLD_PIN, HIGH);

#if ENABLE_FILE_LOG
  if (!SPIFFS.begin(true)) {
    Serial.println("[SPIFFS] mount failed");
  } else {
    Serial.println("[SPIFFS] mounted");
  }
#endif

  gImuOK = M5.Imu.begin();
  Serial.printf("[IMU] begin=%d\n", gImuOK ? 1 : 0);

  Wire.begin(SDA_PIN, SCL_PIN, I2C_HZ);

  if (gSensor.begin(Wire, I2C_HZ, MAX_ADDR)) {
    gHasMAX = true;
    applySensorConfig();
    Serial.println("[MAX3010x] OK");
  } else {
    gHasMAX = false;
    Serial.println("[MAX3010x] NOT FOUND");
  }

  bleInit();
}

void loop() {
  M5.update();

  if (M5.BtnA.wasClicked()) {
    if (gRecording) stopRecording();
    else startRecording();
  }

  if (M5.BtnB.wasDoubleClicked()) {
    powerOffDevice();
  }

  float ax = 0.0f, ay = 0.0f, az = 0.0f;
  if (gImuOK) {
    M5.Imu.getAccel(&ax, &ay, &az);
  }

  const float dAx = ax - gLastAx;
  const float dAy = ay - gLastAy;
  const float dAz = az - gLastAz;
  const float deltaMag = sqrtf(dAx * dAx + dAy * dAy + dAz * dAz);
  gMotionMag = MOTION_ALPHA * deltaMag + (1.0f - MOTION_ALPHA) * gMotionMag;
  gLastAx = ax;
  gLastAy = ay;
  gLastAz = az;

  uint32_t ir = 0;
  if (gHasMAX) {
    gSensor.check();
    ir = gSensor.getIR();
    autoLevel(ir, ir > FINGER_MIN_IR);
  }

  if (gHasMAX && ir > FINGER_MIN_IR && checkForBeat(ir)) {
    const uint32_t now = millis();
    const uint32_t delta = now - gLastBeatMs;

    if (delta > IBI_MIN_MS && delta < IBI_MAX_MS) {
      gBPM = 60000 / (int)delta;
      gLastValidBpm = gBPM;
      gLastValidBpmMs = now;
      gLastBeatSeenMs = now;
    }

    gLastBeatMs = now;
  }

  if (millis() - gLastBeatSeenMs > NO_BEAT_TIMEOUT_MS) {
    gBPM = -1;
  }

  const uint32_t now = millis();
  if (gRecording && (now - gLastSendMs >= SEND_PERIOD_MS)) {
    gLastSendMs = now;
    const int hr = currentHrOut();

    appendSampleToFile(now, hr, ax, ay, az);
    bleSendSample(now, hr, ax, ay, az);
    ++gRowsWritten;
  }

  printHeartbeat(ir);
  drawOverlay(ir, ax, ay, az);

  delay(1);
}