// M5StickC Plus 2 + MAX30102 — BLE Epoch (ML-ready)
// BtnA: Start/Stop session (ONLY then 30s epoch rows are sent + saved)
// BtnB: If NOT recording -> dump file to Serial; If recording -> cycle brightness
//
// Epoch row (every 30s, while recording):
// conf,meanHR,rmssd,activityCount,axMean,ayMean,azMean,axStd,ayStd,azStd,magMean,magStd
//
// BLE: Nordic UART Service (NUS)
// - Service: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
// - TX Notify: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E
// - RX Write : 6E400002-B5A3-F393-E0A9-E50E24DCCA9E

#include <M5Unified.h>
#include <Wire.h>
#include <SPIFFS.h>
#include <esp_task_wdt.h>
#include <esp_log.h>
#include "MAX30105.h"
#include "heartRate.h"
#include <math.h>
#include <NimBLEDevice.h>

#define SDA_PIN 33
#define SCL_PIN 32
#define I2C_HZ  100000
#define MAX_ADDR 0x57

// -------- Sensor config --------
const byte LED_MODE       = 2;      // Red+IR
byte       ledBrightness  = 0xFF;   // higher start -> more stable finger detect
const byte SAMPLE_AVG     = 4;
const int  SAMPLE_RATE_HZ = 100;
const int  PWIDTH_US      = 215;
const int  ADC_RANGE      = 16384;

// -------- Auto-level --------
const uint32_t IR_HARD_HIGH = 240000;
const uint32_t IR_SOFT_HIGH = 170000;
const uint32_t IR_SOFT_LOW  = 60000;
const uint32_t IR_GOOD_MIN  = 70000;
const uint32_t IR_GOOD_MAX  = 150000;
const unsigned long ADJUST_PERIOD_MS = 800;

// -------- Beat limits --------
const uint32_t FINGER_MIN_IR   = 20000;
const unsigned long NO_BEAT_TIMEOUT_MS = 3000;
const unsigned long IBI_MIN_MS = 300;
const unsigned long IBI_MAX_MS = 2400;

// -------- Epoch (30s) --------
const uint32_t EPOCH_MS = 30000;
uint32_t epochStartMs = 0;
uint32_t epochActivityCount = 0;

// -------- Epoch accel features (30s) --------
double axSum=0, aySum=0, azSum=0;
double ax2Sum=0, ay2Sum=0, az2Sum=0;
double magSum=0, mag2Sum=0;
unsigned long accN=0;

// -------- Globals --------
MAX30105 sensor;
bool hasMAX=false, imuOK=false;

// HR smoothing
const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeatMs = 0, lastBeatSeenMs = 0;
int  BPM = -1;

// Overlay / motion
uint32_t lastDrawMs = 0;
float lastAx=0, lastAy=0, lastAz=0;
float motionMag = 0.0f;
const float MOTION_ALPHA = 0.15f;
const float MOTION_THRESH = 0.02f;

// HRV
const int IBI_BUF = 16;
unsigned long ibis[IBI_BUF];
int ibiPos = 0, ibiCount = 0;
float rmssdMs = -1.0f;

// Quality
int confPct = 0;
int consecutiveBeats = 0;

// Mean HR (high confidence only)
double hrSum = 0.0;
unsigned long hrCount = 0;
double meanHR = -1.0;

// Track finger freshness so overlay doesn't "freeze" HR
unsigned long lastFingerSeenMs = 0;

// Session / logging (BtnA controls this)
bool recording = false;
File logFile;
size_t rowsWritten = 0;

// ---------- BLE (NUS / UART) ----------
static NimBLEServer* pServer = nullptr;
static NimBLECharacteristic* pTxCharacteristic = nullptr;
static bool bleConnected = false;
static bool bleAdvertising = false;

#define DEV_NAME          "M5SleepDemo"
#define NUS_SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_CHAR_TX_UUID  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // Notify
#define NUS_CHAR_RX_UUID  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // Write

void bleSendLine(const String& line);

void bleStopAdvertising() {
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  if (adv) adv->stop();
  bleAdvertising = false;
  Serial.println("[BLE] Advertising STOPPED");
}

class MyServerCallbacks : public NimBLEServerCallbacks {
public:
  void onConnect(NimBLEServer* pS, NimBLEConnInfo& connInfo) {
    (void)pS; (void)connInfo;
    bleConnected = true;
    bleStopAdvertising();
    Serial.println("[BLE] ✅ CONNECTED");
    bleSendLine("CONNECTED");
  }

  void onDisconnect(NimBLEServer* pS, NimBLEConnInfo& connInfo, int reason) {
    (void)pS; (void)connInfo; (void)reason;
    bleConnected = false;
    Serial.println("[BLE] ❌ DISCONNECTED -> restart ADV");
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
  Serial.print("[BLE] Service UUID: ");
  Serial.println(NUS_SERVICE_UUID);
}

// Debug + keeps flags consistent (safe)
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

  // Try to increase MTU (phone may accept or ignore)
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

// ✅ FIXED: robust chunked notify, ONE newline at end, no min() dependency
void bleSendLine(const String& line) {
  if (!pTxCharacteristic) return;
  if (!bleConnected) return;

  // Only ONE newline at end (the phone uses '\n' to split lines)
  String msg = line;
  msg += "\n";

  const size_t CHUNK = 20; // safe for default MTU
  const size_t L = msg.length();

  for (size_t i = 0; i < L; i += CHUNK) {
    size_t end = i + CHUNK;
    if (end > L) end = L;

    String part = msg.substring(i, end);
    pTxCharacteristic->setValue((uint8_t*)part.c_str(), part.length());
    pTxCharacteristic->notify();

    delay(8); // helps older phones
  }
}

// ----------------- Helpers -----------------
inline bool fingerPresent(uint32_t ir) { return ir >= FINGER_MIN_IR; }

void resetIBI() {
  ibiPos = 0;
  ibiCount = 0;
  rmssdMs = -1.0f;
}

void resetEpoch() {
  epochStartMs = millis();
  epochActivityCount = 0;

  axSum=aySum=azSum=0;
  ax2Sum=ay2Sum=az2Sum=0;
  magSum=mag2Sum=0;
  accN=0;
}

void resetSessionStats() {
  for (byte i=0;i<RATE_SIZE;i++) rates[i]=0;
  rateSpot = 0;
  BPM = -1;
  lastBeatMs = 0;
  lastBeatSeenMs = 0;

  resetIBI();
  confPct = 0;
  consecutiveBeats = 0;

  hrSum = 0.0;
  hrCount = 0;
  meanHR = -1.0;

  lastFingerSeenMs = 0;

  resetEpoch();
}

void applyConfig() {
  sensor.setup(ledBrightness, SAMPLE_AVG, LED_MODE, SAMPLE_RATE_HZ, PWIDTH_US, ADC_RANGE);
  sensor.setPulseAmplitudeRed(0x00);
  sensor.setPulseAmplitudeGreen(0x00);
  sensor.clearFIFO();
}

bool initMAX30102() {
  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(I2C_HZ);
  delay(80);

  Wire.beginTransmission(MAX_ADDR);
  if (Wire.endTransmission() != 0) return false;
  if (!sensor.begin(Wire)) return false;

  applyConfig();
  resetSessionStats();
  return true;
}

void autoLevel(uint32_t ir, bool finger) {
  if (ir >= IR_HARD_HIGH && ledBrightness >= 0x20) {
    ledBrightness -= 0x10;
    applyConfig();
    return;
  }
  static unsigned long lastAdjust = 0;
  if (millis() - lastAdjust < ADJUST_PERIOD_MS) return;
  lastAdjust = millis();

  bool changed=false;
  if (ir > IR_SOFT_HIGH && ledBrightness >= 0x14) { ledBrightness -= 0x04; changed=true; }
  else if (finger && ir < IR_SOFT_LOW && ledBrightness <= 0xFB) { ledBrightness += 0x04; changed=true; }
  else if (finger && ir > IR_GOOD_MAX && ledBrightness >= 0x14) { ledBrightness -= 0x04; changed=true; }
  else if (finger && ir < IR_GOOD_MIN && ledBrightness <= 0xFB) { ledBrightness += 0x04; changed=true; }

  if (changed) applyConfig();
}

void computeRMSSD() {
  if (BPM <= 0 || ibiCount < 4) { rmssdMs = -1.0f; return; }

  int K = (ibiCount < 12) ? ibiCount : 12;
  if (K < 4) { rmssdMs = -1.0f; return; }

  unsigned long win[12];
  int idx = (ibiPos - 1 + IBI_BUF) % IBI_BUF;
  for (int i = 0; i < K; i++) { win[i] = ibis[idx]; idx = (idx - 1 + IBI_BUF) % IBI_BUF; }

  double meanIbi = 0.0;
  for (int i = 0; i < K; i++) meanIbi += win[i];
  meanIbi /= K;

  double sumSq = 0.0;
  int pairs = 0;
  for (int i = 0; i < K - 1; i++) {
    long diff = (long)win[i] - (long)win[i + 1];
    long adiff = labs(diff);
    if (adiff > 250) continue;
    if (adiff > 0.20 * meanIbi) continue;
    sumSq += (double)diff * (double)diff;
    pairs++;
  }

  rmssdMs = (pairs >= 3) ? sqrt(sumSq / pairs) : -1.0f;
}

// ---- Recording helpers ----
bool startRecording() {
  resetSessionStats();

  logFile = SPIFFS.open("/hr_demo.csv", FILE_WRITE);
  if (!logFile) {
    Serial.println("[ERR] open /hr_demo.csv failed");
    return false;
  }

  logFile.println("conf,meanHR,rmssd,activityCount,axMean,ayMean,azMean,axStd,ayStd,azStd,magMean,magStd");
  logFile.flush();

  rowsWritten = 0;
  recording = true;
  Serial.println("[REC] started (BtnA) -> epochs will send every 30s");
  return true;
}

void stopRecording() {
  if (recording) {
    if (logFile) { logFile.flush(); logFile.close(); }
    recording = false;
    Serial.printf("[REC] stopped (BtnA) rows=%u\n", (unsigned)rowsWritten);
  }
}

void dumpFileToSerial() {
  File f = SPIFFS.open("/hr_demo.csv", FILE_READ);
  if (!f) { Serial.println("[INFO] No /hr_demo.csv found"); return; }
  Serial.println("--- BEGIN /hr_demo.csv ---");
  while (f.available()) { Serial.println(f.readStringUntil('\n')); delay(1); }
  f.close();
  Serial.println("--- END /hr_demo.csv ---");
}

// ---- overlay ----
void drawOverlay(uint32_t ir) {
  auto& d = M5.Display;
  if (millis() - lastDrawMs < 100) return;
  lastDrawMs = millis();

  d.startWrite();
  d.fillScreen(TFT_BLACK);

  bool finger = fingerPresent(ir);
  d.fillCircle(8, 8, 5, finger ? TFT_GREEN : TFT_RED);

  if (recording) {
    int w = 42, h = 16;
    int x = d.width() - w - 6, y = 4;
    d.fillRoundRect(x, y, w, h, 6, TFT_RED);
    d.setTextSize(1);
    d.setTextColor(TFT_WHITE, TFT_RED);
    d.setCursor(x+10, y+4);
    d.print("REC");
  }

  d.setTextSize(1);
  d.setTextColor(TFT_WHITE, TFT_BLACK);
  d.setCursor(6, 18);
  d.printf("BLE:%s ADV:%s", bleConnected ? "ON" : "OFF", bleAdvertising ? "ON" : "OFF");

  d.setCursor(6, 30);
  d.printf("Name:%s", DEV_NAME);

  d.setTextSize(2);
  d.setTextColor(TFT_YELLOW, TFT_BLACK);
  d.setCursor(6, 44);
  d.printf("conf:%d%%", confPct);

  d.setTextSize(1);
  d.setTextColor(TFT_CYAN, TFT_BLACK);
  d.setCursor(6, 70);
  d.printf("act:%lu", (unsigned long)epochActivityCount);

  d.setCursor(6, 94);
  bool fingerRecent = (millis() - lastFingerSeenMs) < 1200;
  if (fingerRecent && meanHR > 0) d.printf("HR:%.0f", meanHR);
  else                            d.printf("HR:--");

  d.setCursor(6, 106);
  if (fingerRecent && rmssdMs > 0) d.printf("RMSSD:%.0f", rmssdMs);
  else                             d.printf("RMSSD:--");

  d.endWrite();
}

// ----------------- Setup/Loop -----------------
void setup() {
  esp_log_level_set("task_wdt", ESP_LOG_NONE);
  esp_task_wdt_deinit();

  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setRotation(3);
  M5.Display.setBrightness(255);

  Serial.begin(115200);
  delay(300);
  Serial.println("Boot...");

  if (!SPIFFS.begin(true)) Serial.println("[ERR] SPIFFS mount failed");

  imuOK = M5.Imu.begin();
  if (!imuOK) Serial.println("[WARN] IMU init failed");

  hasMAX = initMAX30102();
  if (!hasMAX) Serial.println("[WARN] MAX30102 not found on I2C");

  bleInit();
  Serial.println("[INFO] Connect with phone app, enable Notify on TX char ...0003");
}

void loop() {
  M5.update();
  blePollConnectionStatus();

  // Buttons
  if (M5.BtnA.wasClicked()) {
    if (!recording) startRecording();
    else            stopRecording();
    delay(5);
  }

  if (M5.BtnB.wasClicked()) {
    if (!recording) dumpFileToSerial();
    else {
      static int mode = 0;
      mode = (mode + 1) % 3;
      int b = (mode == 0) ? 255 : (mode == 1 ? 96 : 0);
      M5.Display.setBrightness(b);
    }
    delay(5);
  }

  // MAX30102 reading
  static uint32_t ir = 0;
  static uint32_t lastSampleMs = 0;

  if (hasMAX) {
    sensor.check();
    if (sensor.available()) {
      ir = sensor.getIR();
      sensor.nextSample();
      lastSampleMs = millis();
    } else {
      if (millis() - lastSampleMs > 1500) {
        Serial.println("[MAX] no samples -> recover");
        sensor.clearFIFO();
        applyConfig();
        lastSampleMs = millis();
      }
    }
  } else {
    ir = 0;
  }

  // Motion processing
  float ax=0, ay=0, az=0;
  if (imuOK) M5.Imu.getAccel(&ax,&ay,&az);

  float dAx = ax - lastAx, dAy = ay - lastAy, dAz = az - lastAz;
  float deltaMag = sqrtf(dAx*dAx + dAy*dAy + dAz*dAz);
  motionMag = MOTION_ALPHA*deltaMag + (1.0f - MOTION_ALPHA)*motionMag;
  lastAx=ax; lastAy=ay; lastAz=az;

  if (recording) {
    if (deltaMag > MOTION_THRESH) epochActivityCount++;

    accN++;
    axSum += ax; aySum += ay; azSum += az;
    ax2Sum += (double)ax*ax;
    ay2Sum += (double)ay*ay;
    az2Sum += (double)az*az;

    float mag = sqrtf(ax*ax + ay*ay + az*az);
    magSum += mag;
    mag2Sum += (double)mag*mag;
  }

  // PPG processing
  bool finger = fingerPresent(ir);
  if (finger) lastFingerSeenMs = millis();
  if (hasMAX) autoLevel(ir, finger);

  if (hasMAX && finger) {
    if (checkForBeat(ir)) {
      unsigned long now = millis();
      if (lastBeatMs != 0) {
        unsigned long IBI = now - lastBeatMs;
        if (IBI >= IBI_MIN_MS && IBI <= IBI_MAX_MS) {
          float bpmInst = 60000.0f / (float)IBI;
          if (bpmInst > 25.0f && bpmInst < 220.0f) {

            rates[rateSpot++] = (byte)lroundf(bpmInst);
            rateSpot %= RATE_SIZE;

            int valid = 0, sum = 0;
            for (byte i=0; i<RATE_SIZE; i++) {
              if (rates[i] > 0) { sum += rates[i]; valid++; }
            }
            BPM = (valid >= 2) ? (sum / valid) : (int)lroundf(bpmInst);

            lastBeatSeenMs = now;

            if (ibiCount == 0) {
              ibis[0] = IBI;
              ibis[1] = IBI;
              ibiPos = 2;
              ibiCount = 2;
            } else {
              ibis[ibiPos] = IBI;
              ibiPos = (ibiPos + 1) % IBI_BUF;
              if (ibiCount < IBI_BUF) ibiCount++;
            }

            consecutiveBeats = min(consecutiveBeats + 1, 10);
            int base = 20 + consecutiveBeats * 8;
            int irPenalty = ((ir < IR_GOOD_MIN) || (ir > IR_GOOD_MAX)) ? 15 : 0;
            int motionPenalty = (motionMag > 0.20f) ? 25 : 0;
            confPct = base - irPenalty - motionPenalty;
            confPct = constrain(confPct, 0, 100);

            if (confPct >= 70 && BPM > 0) {
              hrSum += (double)BPM;
              hrCount++;
              meanHR = hrSum / (double)hrCount;
            }
          }
        }
      }
      lastBeatMs = now;
    }

    if (lastBeatSeenMs == 0 || (millis() - lastBeatSeenMs) > NO_BEAT_TIMEOUT_MS) {
      BPM = -1;
      consecutiveBeats = 0;
      confPct = 0;
      resetIBI();
    }
  } else {
    lastBeatMs = 0;
    BPM = -1;
    consecutiveBeats = 0;
    confPct = 0;
    resetIBI();
  }

  computeRMSSD();

  // Epoch end (only while recording)
  if (recording) {
    if (epochStartMs == 0) epochStartMs = millis();
    if (millis() - epochStartMs >= EPOCH_MS) {
      float rmssdOut  = (confPct >= 70 && BPM > 0) ? rmssdMs : -1.0f;
      float meanHROut = (meanHR > 0) ? (float)meanHR : -1.0f;

      auto stdFrom = [&](double s, double s2) -> float {
        if (accN < 2) return 0.0f;
        double mean = s / (double)accN;
        double var  = (s2 / (double)accN) - (mean * mean);
        if (var < 0) var = 0;
        return (float)sqrt(var);
      };

      float axMean = (accN>0) ? (float)(axSum/accN) : 0;
      float ayMean = (accN>0) ? (float)(aySum/accN) : 0;
      float azMean = (accN>0) ? (float)(azSum/accN) : 0;

      float axStd = stdFrom(axSum, ax2Sum);
      float ayStd = stdFrom(aySum, ay2Sum);
      float azStd = stdFrom(azSum, az2Sum);

      float magMean = (accN>0) ? (float)(magSum/accN) : 0;
      float magStd  = stdFrom(magSum, mag2Sum);

      String line =
        String(confPct) + "," +
        String(meanHROut,1) + "," +
        String(rmssdOut,1) + "," +
        String(epochActivityCount) + "," +
        String(axMean,5) + "," + String(ayMean,5) + "," + String(azMean,5) + "," +
        String(axStd,5)  + "," + String(ayStd,5)  + "," + String(azStd,5)  + "," +
        String(magMean,5) + "," + String(magStd,5);

      bleSendLine(line);
      Serial.print("[EPOCH] "); Serial.println(line);

      if (logFile) {
        logFile.println(line);
        logFile.flush();
        rowsWritten++;
      }

      resetEpoch();
    }
  }

  drawOverlay(ir);
  delay(10);
}
