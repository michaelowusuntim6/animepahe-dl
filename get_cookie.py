#!/usr/bin/env python3
import json
import os
import shutil
import sys
import time
import undetected_chromedriver as uc


def find_executable(*names):
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    return None


def get_cookie():
    options = uc.ChromeOptions()
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-gpu")
    options.add_argument("--disable-dev-shm-usage")

    # Prefer an explicit Chrome binary, otherwise search common names
    # ($CHROME_BIN can override, e.g. CHROME_BIN=/snap/bin/chromium).
    chrome_bin = os.environ.get("CHROME_BIN") or find_executable(
        "google-chrome-stable", "google-chrome", "chromium", "chromium-browser",
    ) or "/usr/bin/google-chrome-stable"
    if os.path.exists(chrome_bin):
        options.binary_location = chrome_bin

    # Use an installed chromedriver if present; otherwise let
    # undetected_chromedriver download a matching one automatically
    # ($CHROMEDRIVER_BIN can override).
    chromedriver_bin = os.environ.get("CHROMEDRIVER_BIN") or find_executable("chromedriver")

    driver = uc.Chrome(
        options=options,
        driver_executable_path=chromedriver_bin,
    )

    try:
        driver.get("https://animepahe.pw")
        time.sleep(8)

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
