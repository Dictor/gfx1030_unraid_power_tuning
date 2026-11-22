# Radeon PRO W6800 (GFX1030) 리눅스 제로팬(0 RPM) + SMU 순정 커브 구현 문서

> **문서 상태**: 커널 패치 구현 완료 (`patches/w6800-zerofan-unlock.patch` — 방법 A 채택)  
> **대상 환경**: Unraid OS (Linux 6.18.x-Unraid)  
> **대상 GPU**: AMD Radeon PRO W6800 (Navi 21 GL-XL / `0x1002:0x73a3`, 서브시스템 `0x1002:0x0e1e`)

---

## 1. 배경 및 기술 분석

### 1.1 윈도우 vs 리눅스 동작 차이 및 근본 원인
* **현상**:
  * **윈도우**: AMD 소프트웨어 및 드라이버 제어를 통해 팬이 완전히 정지하는 **물리적 0 RPM (제로팬)**이 정상 작동함.
  * **리눅스 (순정 드라이버)**:
    * 자동 모드(`pwm1_enable=2`): VBIOS 순정 팬 커브에 의해 아이들 시 최소 **1,200 RPM**으로 회전.
    * 수동 모드(`pwm1_enable=1`): `echo 0 > pwm1`을 주입해도 팬이 멈추지 않고 **777 RPM**에 고정됨.
* **원인 분석**:
  * 리눅스 `sysfs`의 `pwm1=0`은 SMU에 "수동 PWM 듀티 0%"(`FDO_PWM_MODE_STATIC`)를 요구하는 방식입니다. 하지만 Navi 21(Sienna Cichlid)의 SMU 펌웨어(PMFW)는 **수동 PWM 모드 진입 시 하드웨어 보호를 위해 자체 최소 회전수(777 RPM)로 클램프**합니다.
  * 반면 윈도우 드라이버는 PWM 듀티를 0으로 깎는 것이 아니라, SMU의 **`FanZeroRpmEnable` 펌웨어 상태 머신 자체를 활성화**하여 자동 제어 상태에서 펌웨어가 팬 전원과 모터를 완전히 끄도록(0 RPM) 유도합니다.
  * W6800은 워크스테이션 카드로 VBIOS PowerPlay Table(`PPTable_t`)에 `FanZeroRpmEnable = 0`, OverDrive `ODCAP_FAN_ZERO_RPM_CONTROL = 0`으로 잠겨 있어 순정 리눅스 `amdgpu` 드라이버에서는 제로팬 진입이 불가능합니다.

### 1.2 아이들 온도 특성 (VRAM 42°C 고려)
* W6800의 아이들 상태 온도는 코어(Edge)/핫스팟(Junction) 약 `36°C`, **VRAM(Memory) 약 `42°C`**입니다.
* 따라서 `max(코어, 핫스팟, VRAM)` 기준 제로팬 임계값은 **`45°C 이하 제로팬(0 RPM)` / `49°C 이상 SMU 순정 커브 복귀`**(4°C 히스테리시스)로 설정해야 아이들 상태에서 안정적으로 0 RPM이 유지됩니다.

---

## 2. 방법 A 아키텍처 (`pwm1=0` 제로팬 + `pwm1_enable=2` SMU 순정 커브)

```
+-----------------------------------------------------------------------------------+
|                               Unraid OS (User-space)                              |
|                                                                                   |
|   +---------------------------------------------------------------------------+   |
|   |                     유저스페이스 온도 제어 스크립트                        |   |
|   |  - max(Edge, Hotspot, VRAM) <= 45°C --> pwm1_enable = 1, pwm1 = 0 (0 RPM) |   |
|   |  - max(Edge, Hotspot, VRAM) >= 49°C --> pwm1_enable = 2 (SMU 순정 커브)   |   |
|   |  - 팬 회전 중에는 SMU 내장 순정 커브(1,200 RPM~)가 100% 하드웨어 제어     |   |
|   +-------------------------------------+-------------------------------------+   |
|                                         | sysfs 인터페이스                        |
+-----------------------------------------|-----------------------------------------+
|   Linux Kernel (amdgpu.ko - patches/w6800-zerofan-unlock.patch)                   |
|   1. 부팅 시(pwm1_enable=2): FanZeroRpmEnable = 0 유지 (100% 순정 팬 커브 동작)   |
|   2. pwm1 = 0 입력 시: FanZeroRpmEnable = 1 (Stop=55°C, Start=60°C) 활성화 후     |
|      SMU 자동 제어 엔진에 위임 -> 물리적 0 RPM 정지                               |
|   3. pwm1 > 0 입력 시: FanZeroRpmEnable = 0 복원 후 수동 PWM(777 RPM~) 제어       |
|   4. pwm1_enable = 2 입력 시: FanZeroRpmEnable = 0 복원 -> SMU 순정 커브 즉시 복귀|
|   5. [하드웨어 Fail-Safe]: 유저 데몬이 죽더라도 60°C 도달 시 SMU가 즉시 팬 가동   |
+-----------------------------------------------------------------------------------+
```

---

## 3. 커널 패치 세부 구현 (`patches/w6800-zerofan-unlock.patch`)

수정 대상: `drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c`  
대상 식별: `adev->pdev->vendor == 0x1002 && adev->pdev->device == 0x73a3` (Radeon PRO W6800 전용 격리, 타 GPU 영향 0%)

1. **초기화 시점 (`sienna_cichlid_patch_pptable_quirk`)**:
   * `PPTable_t` 내 `FanStopTemp = 55`, `FanStartTemp = 60` (SMU 하드웨어 비상 가동 온도), `FanZeroRpmEnable = 0` 설정.
   * `overdrive_table` 내 `SMU_11_0_7_ODCAP_FAN_ZERO_RPM_CONTROL = 1` 및 범위(`25~60°C`) 언락.
   * 부팅 직후 기본 상태(`pwm1_enable = 2`)에서는 `FanZeroRpmEnable = 0`이므로 100% 순정 VBIOS 커브(1,200 RPM~)로 동작.
2. **제로팬 토글 헬퍼 (`sienna_cichlid_w6800_zerofan_unlock`)**:
   * `noinline` 심볼로 선언되어 빌드 시 `nm amdgpu.ko | grep sienna_cichlid_w6800_zerofan_unlock`으로 바이너리 검증 가능.
   * `PPTable_t`(`smu_cmn_write_pptable`)와 `OverDriveTable_t`(`smu_cmn_update_table`) 양쪽 모두에 `FanZeroRpmEnable = 1/0` 및 `StopTemp = 55°C`, `StartTemp = 60°C`를 동기화하여 `ppfeaturemask` 설정 여부와 무관하게 즉시 SMU에 반영.
3. **수동 PWM 0 매핑 (`sienna_cichlid_set_fan_speed_pwm`)**:
   * **상태 가드 및 Fast-Path (`*fan_zero_rpm_enable`)**: 불필요한 SMU 메일박스 충돌(`Start/Stop smc FAN CONTROL feature failed!`)을 방지하기 위해 현재 `*fan_zero_rpm_enable` 상태를 먼저 확인합니다.
   * `speed == 0` (`echo 0 > pwm1`): 이미 제로팬 상태(`*fan_zero_rpm_enable != 0`)면 즉시 `0`을 반환해 중복 메일박스 호출을 막고, 처음 진입할 때만 `sienna_cichlid_w6800_zerofan_unlock(smu, true)` + `AMD_FAN_CTRL_AUTO`로 팬을 **0 RPM** 정지시킵니다.
   * `speed > 0` (`echo N > pwm1`): 제로팬에서 빠져나오는 **1회 전환 시점(`*fan_zero_rpm_enable != 0`)에만** `sienna_cichlid_w6800_zerofan_unlock(smu, false)` 및 `AMD_FAN_CTRL_MANUAL` 전환을 수행합니다. 이미 수동 모드(`*fan_zero_rpm_enable == 0`)인 상태에서의 모든 `pwm1 > 0` 속도 변경은 **SMU 메일박스를 단 1회도 호출하지 않고** 즉시 순수 MMIO 레지스터(`CG_FDO_CTRL0`) 쓰기로 직행합니다.
4. **SMU 순정 커브 복귀 (`sienna_cichlid_set_fan_control_mode`)**:
   * `echo 2 > pwm1_enable` (`AMD_FAN_CTRL_AUTO`) 인입 시 `sienna_cichlid_w6800_zerofan_unlock(smu, false)`를 호출하여 `FanZeroRpmEnable = 0`으로 원복하고 SMU 자동 제어 활성화 -> **W6800 순정 VBIOS 팬 커브(1,200 RPM+)로 100% 복귀**.
5. **상태 일관성 유지 (`sienna_cichlid_get_fan_control_mode`)**:
   * `pwm1 = 0` 제로팬 동작 중 내부적으로 SMU 자동 제어 비트가 켜져 있더라도, 사용자가 설정한 모드가 `AMD_FAN_CTRL_MANUAL`(`pwm1_enable = 1`)이면 `cat pwm1_enable`이 `1`을 반환하도록 유지하여 연속적인 `pwm1` 쓰기 호환성 보장.

---

## 4. 빌드 및 사용 방법

### 4.1 WSL 대화형 빌드 (`build_wsl.sh`)
```bash
./build_wsl.sh 6.18.58-Unraid
```
실행 시 영문 대화형 프롬프트가 표시됩니다:
```text
Select which W6800 patch(es) to include in amdgpu.ko:
  [1] 120W Minimum Powercap Unlock only (w6800-powercap-min-120W.patch)
  [2] Zero-Fan (0 RPM) Unlock only      (w6800-zerofan-unlock.patch)
  [3] Both Patches (120W Powercap + Zero-Fan Unlock) [Default]

Enter selection [1-3] (default: 3):
```
* `2` 또는 `3`(기본값)을 선택하면 `patches/w6800-zerofan-unlock.patch`가 포함되며, 빌드 완료 시 `sienna_cichlid_w6800_zerofan_unlock` 심볼이 자동으로 검증됩니다.

### 4.2 유저스페이스 데몬 예시 (`max(Edge, Hotspot, VRAM) <= 45°C` 제로팬 / `>= 49°C` 순정 커브)
```bash
#!/usr/bin/env bash
# w6800-zerofan.sh - 45°C 이하 0 RPM 제로팬, 49°C 이상 W6800 SMU 순정 커브 복귀

for dev in /sys/bus/pci/devices/*; do
  if [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x1002" ] && \
     [ "$(cat "$dev/device" 2>/dev/null)" = "0x73a3" ]; then
    HWMON=$(ls -d "$dev"/hwmon/hwmon* 2>/dev/null | head -n 1)
    break
  fi
done

[ -n "${HWMON:-}" ] || { echo "W6800 hwmon not found"; exit 1; }
trap 'echo 2 > "$HWMON/pwm1_enable" 2>/dev/null; exit 0' EXIT INT TERM

STATE="AUTO"
while true; do
  T_EDGE=$(( $(cat "$HWMON/temp1_input") / 1000 ))
  T_JUNC=$(( $(cat "$HWMON/temp2_input") / 1000 ))
  T_MEM=$((  $(cat "$HWMON/temp3_input") / 1000 ))

  MAX_T=$T_EDGE
  [ "$T_JUNC" -gt "$MAX_T" ] && MAX_T=$T_JUNC
  [ "$T_MEM"  -gt "$MAX_T" ] && MAX_T=$T_MEM

  if [ "$MAX_T" -le 45 ] && [ "$STATE" != "ZEROFAN" ]; then
    echo 1 > "$HWMON/pwm1_enable"
    echo 0 > "$HWMON/pwm1"
    STATE="ZEROFAN"
  elif [ "$MAX_T" -ge 49 ] && [ "$STATE" != "AUTO" ]; then
    echo 2 > "$HWMON/pwm1_enable"
    STATE="AUTO"
  fi

  sleep 2
done
```

---

## 5. 안전성 검증 및 시나리오별 동작 요약

| 시나리오 | 동작 및 안전 메커니즘 |
|---|---|
| **부팅 직후 (스크립트 미실행)** | `pwm1_enable=2` 및 `FanZeroRpmEnable=0` 기본값 -> **순정 W6800 팬 커브(1,200 RPM~)** 동작 |
| **아이들 (`max(코어, 핫스팟, VRAM) <= 45°C`)** | `pwm1_enable=1 && pwm1=0` -> **물리적 0 RPM 완전 무소음** 유지 (아이들 VRAM 42°C 여유 확보) |
| **부하 진입 (`max(코어, 핫스팟, VRAM) >= 49°C`)** | `pwm1_enable=2` -> `FanZeroRpmEnable=0` 복원 후 **100% 공장 출하 SMU 순정 팬 커브**가 직접 회전수 제어 |
| **수동 저속 제어 (`pwm1_enable=1 && pwm1=50`)** | `pwm1 > 0` 인입 시 `FanZeroRpmEnable=0` 및 수동 PWM 모드 전환 -> **777 RPM 이상 수동 회전** 정상 작동 |
| **데몬 정상 종료 (`SIGTERM` / `SIGINT`)** | `trap`에 의해 즉시 `pwm1_enable=2` (순정 커브)로 복구 |
| **데몬 비정상 종료 (`kill -9` 등)** | 제로팬 상태에서 온도가 상승하더라도 **60°C 도달 시 SMU 하드웨어 Fail-Safe(`FanStartTemp = 60`)가 강제로 팬을 가동**하여 과열 원천 차단 |
