#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// 4つのFSRピン
const int FSR1 = 32;
const int FSR2 = 33;
const int FSR3 = 34;
const int FSR4 = 35;

// BLEの「掲示板」を識別するための専用ID（UUID）
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;

// スマホが繋がったか・切れたかを検知する機能
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("スマホと接続されました！");
    };
    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("スマホとの接続が切れました。");
      // 切れたら再び掲示板を公開して待つ
      pServer->getAdvertising()->start();
    }
};

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);

  // --- ここからBLEの準備 ---
  BLEDevice::init("ESP32_SmartSensor"); // スマホから見えるデバイス名
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // データを送信（Notify）する設定
  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );
  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();
  pServer->getAdvertising()->start();
  
  Serial.println("BLE起動完了！スマホからの接続を待っています...");
}

void loop() {
  // スマホが繋がっている時だけデータを送る
  if (deviceConnected) {
    int val1 = analogRead(FSR1);
    int val2 = analogRead(FSR2);
    int val3 = analogRead(FSR3);
    int val4 = analogRead(FSR4);

    // "1024,512,0,4095" のような文字列を作る
    char sensorDataString[32];
    snprintf(sensorDataString, sizeof(sensorDataString), "%d,%d,%d,%d", val1, val2, val3, val4);

    // 文字列をBLEの掲示板に書き込んで、スマホにお知らせ（Notify）する
    pCharacteristic->setValue(sensorDataString);
    pCharacteristic->notify();

    Serial.print("送信データ: ");
    Serial.println(sensorDataString);
    
    // データ送信の間隔（早すぎるとスマホがパンクするので0.1秒待つ）
    delay(100); 
  }
}
