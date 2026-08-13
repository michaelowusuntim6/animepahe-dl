#!/usr/bin/env python3
import json
import os
import sys
import time
import undetected_chromedriver as uc

# Termux paths
CHROME_BIN = "/data/data/com.termux/files/usr/bin/chromium-browser"
CHROMEDRIVER_BIN = "/data/data/com.termux/files/usr/bin/chromedriver"

# Ensure the .exe symlink exists for undetected_chromedriver
if not os.path.exists(CHROMEDRIVER_BIN + ".exe"):
    try:
        os.symlink(CHROMEDRIVER_BIN, CHROMEDRIVER_BIN + ".exe")
    except Exception:
        pass

def get_cookie():
    options = uc.ChromeOptions()
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-gpu")
    options.add_argument("--disable-dev-shm-usage")
    options.binary_location = CHROME_BIN

    driver = uc.Chrome(
        options=options,
        driver_executable_path=CHROMEDRIVER_BIN,
    )

    try:
        driver.get("https://animepahe.pw")
        time.sleep(12)  # give Cloudflare time
        cf = None
        for _ in range(60):
            cookies = driver.get_cookies()
            for c in cookies:
                if c["name"] == "cf_clearance":
                    cf = c["value"]
                    break
            if cf:
                break
            time.sleep(1)
        if not cf:
            raise TimeoutError("cf_clearance not found")
        ua = driver.execute_script("return navigator.userAgent;")
        return cf, ua
    finally:
        driver.quit()

if __name__ == "__main__":
    try:
        cf, ua = get_cookie()
        print(json.dumps({"cf": cf, "ua": ua}))
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)
