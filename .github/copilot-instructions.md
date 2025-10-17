# 🧩 AzerothCore WotLK Server (Windows 11 Build Environment)

AzerothCore is an open-source **World of Warcraft 3.3.5a** server emulator written in C++ with modular architecture.  
These instructions apply to **Windows 11 x64**, **Visual Studio 2022 Preview**, **CMake 3.31+**, and **MySQL 8.4**.  

Always follow the steps below — use PowerShell, not Bash. Only refer to upstream Linux instructions when this document and the actual repository diverge.

---

## ⚙️ Initial Setup

### 1. Required Software
Install these once:
| Component | Version | Notes |
|------------|----------|-------|
| **Visual Studio 2022 Preview** | Latest | Include “Desktop Development with C++” workload |
| **CMake** | ≥ 3.31 | `cmake --version` |
| **MySQL Server 8.4.x** | 64-bit | Default instance, TCP 3306 |
| **OpenSSL 3.x for Windows** | 64-bit | e.g., from [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) |
| **Git for Windows** | Latest | Required for `git pull --recurse-submodules` |
| **PowerShell 7+** | (Built-in on Win 11) | Required for scripts below |

---

## 🏗️ Build Process

### 1. Prepare Environment
Open a **Developer PowerShell for VS 2022** and run:

```powershell
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -prerelease -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -DevCmdArguments '-arch=x64'
```

### 2. Configure Build (CMake)
```powershell
j:
cd "J:\Code\Games\wow\servers\liyunfan1223-azerothcore-wotlk\Build"

cmake --fresh -S .. -B . -G "Visual Studio 17 2022" -A x64 `
  -DTOOLS_BUILD=all `
  -DLUA_VERSION=luajit `
  -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc" `
  -DCMAKE_CXX_FLAGS_RELEASE="/O2 /Ob2 /Oi"
```

### 3. Build (MSBuild via CMake)
```powershell
cmake --build . --target ALL_BUILD --config RelWithDebInfo -- /m:16 /p:UseMultiToolTask=true
```

### 4. Post-Build Copies (if missing)
```powershell
Copy-Item "C:\Program Files\MySQL\MySQL Server 8.4\lib\libmysql.dll" -Destination .\bin\RelWithDebInfo
Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libcrypto-3-x64.dll" -Destination .\bin\RelWithDebInfo
Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libssl-3-x64.dll" -Destination .\bin\RelWithDebInfo
```

Binaries appear in:
```
Build\bin\RelWithDebInfo\
  ├── authserver.exe
  └── worldserver.exe
```

---

## 🧩 Module Setup

Modules are in `modules\<module>\src` with configuration in:
```
Build\bin\RelWithDebInfo\configs\modules\<module>.conf.dist
```

Rename and edit each file for activation:
```
copy mod-xyz.conf.dist mod-xyz.conf
```

> ⚠️ Do **not** delete the `.dist` files — AzerothCore loads both.

---

## 🗄️ Database Initialization

1. Start MySQL (Service “MYSQL80” or “MySQL”)
2. Import base SQLs:
   ```bash
   mysql -u root -p < data/sql/base/auth_database.sql
   mysql -u root -p < data/sql/base/characters_database.sql
   mysql -u root -p < data/sql/base/world_database.sql
   ```
3. Import each module’s SQLs from  
   `modules\<module>\data\sql\db-world\*.sql`
4. Update connection info in:
   ```
   Build\bin\RelWithDebInfo\configs\worldserver.conf
   Build\bin\RelWithDebInfo\configs\authserver.conf
   ```

---

## ▶️ Running the Server

Run from the same folder as the binaries:
```powershell
.\authserver.exe
.\worldserver.exe
```

To reload Eluna Lua scripts without restart:
```
.reload eluna
```

---

## 🧠 Debugging Notes

| Scenario | Build Type | Command or Setting |
|-----------|-------------|--------------------|
| Crash investigation | **Debug** | Run from Visual Studio → Local Windows Debugger |
| Optimized build | **RelWithDebInfo** | Default recommended |
| Enable LuaJIT | `-DLUA_VERSION=luajit` | Already configured |
| Force Win 11 API level | `/D_WIN32_WINNT=0x0A00` | Applied globally |
| Eluna script reload | `.reload eluna` | In worldserver console |

---

## 💾 MySQL & Threads (Worldserver.conf)

Example safe thread configuration to prevent deadlocks:

```ini
LoginDatabase.WorkerThreads     = 1
WorldDatabase.WorkerThreads     = 1
CharacterDatabase.WorkerThreads = 1

LoginDatabase.SynchThreads     = 2
WorldDatabase.SynchThreads     = 2
CharacterDatabase.SynchThreads = 2
```

---

## 🧱 Directory Layout

```
J:\Code\Games\wow\servers\liyunfan1223-azerothcore-wotlk
├── Build\                    # CMake build output
│   ├── bin\RelWithDebInfo\  # Executables, configs, logs
│   └── deps\                 # External single-header libs (nlohmann, httplib)
├── modules\                  # Custom modules (Eluna, playerbots, etc.)
├── deps\nlohmann\json.hpp   # JSON single-header
├── data\sql\base\          # Core SQL schemas
├── lua_scripts\              # Eluna Lua scripts
└── CMakeLists.txt
```

---

## 🛠️ Troubleshooting

| Symptom | Likely Cause | Fix |
|----------|--------------|-----|
| `json.hpp not found` | `deps/nlohmann/json.hpp` missing | Copy it manually |
| Crash ~60 s after start | Debug vs. release mismatch | Rebuild with `/EHsc /O2 /Ob2 /Oi` |
| Server exits silently | DB thread deadlock | Set WorkerThreads = 1 |
| Eluna error on damage | Null attacker | Add null-checks in `OnDamage()` |
| SQL missing | Module SQLs not imported | Import manually before first run |

---

## ✅ Best Practices

- Always run CMake with `--fresh` when upgrading or switching modules  
- Use **RelWithDebInfo** for normal runs (debug symbols + optimized)  
- Keep MySQL ≤ 8.4 for compatibility (9.x untested)  
- Reload Lua scripts dynamically instead of restarting the server  
- Keep `deps\` single-headers (`nlohmann`, `httplib`, etc.) under version control  
