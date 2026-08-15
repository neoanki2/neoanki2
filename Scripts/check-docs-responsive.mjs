#!/usr/bin/env node

import process from "node:process";

const modulePath = process.env.PLAYWRIGHT_MODULE || "playwright";
const { chromium } = await import(modulePath);
const baseURL = process.argv[2] || "http://127.0.0.1:4173";
const widths = [375, 768, 1024];
const routes = ["/", "/api/", "/api/decks/", "/user/developer/"];
const browser = await chromium.launch({ headless: true });
const failures = [];

try {
  for (const width of widths) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    for (const route of routes) {
      await page.goto(new URL(route, baseURL).href, { waitUntil: "networkidle" });
      const result = await page.evaluate(() => {
        const viewportWidth = document.documentElement.clientWidth;
        const overflowingCode = [...document.querySelectorAll("pre")]
          .filter((element) => {
            const bounds = element.getBoundingClientRect();
            return bounds.left < -1 || bounds.right > viewportWidth + 1;
          })
          .length;
        return {
          pageOverflow: document.documentElement.scrollWidth > viewportWidth + 1,
          overflowingCode,
        };
      });
      if (result.pageOverflow) failures.push(`${width}px ${route}: page-level horizontal overflow`);
      if (result.overflowingCode) failures.push(`${width}px ${route}: code block escapes its container`);
      if (route === "/" && !(await page.locator(".landing-footer-publication").isVisible())) {
        failures.push(`${width}px ${route}: source revision is not visible in the footer`);
      }

      const toggle = page.locator(".nav-toggle");
      if (await toggle.isVisible()) {
        await toggle.focus();
        await page.keyboard.press("Enter");
        if ((await toggle.getAttribute("aria-expanded")) !== "true") {
          failures.push(`${width}px ${route}: navigation cannot be opened from the keyboard`);
        }
        await page.keyboard.press("Escape");
      }
    }
    await page.close();
  }
} finally {
  await browser.close();
}

for (const failure of failures) console.error(`error: ${failure}`);
if (failures.length) process.exit(1);
console.log(`Responsive documentation checks passed at ${widths.join(", ")} pixels.`);
