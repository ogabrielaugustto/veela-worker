import { chromium, type Page } from "playwright";

import { ExternalServiceError } from "../shared/errors.js";

export type ScreenshotResult = {
  buffer: Buffer;
  finalUrl: string;
  capturedAt: string;
};

const PAGE_TIMEOUT_MS = 45_000;
const PRIMARY_NAVIGATION_TIMEOUT_MS = 20_000;
const LOAD_STATE_TIMEOUT_MS = 10_000;
const STABILIZATION_DELAY_MS = 1_500;
const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Safari/537.36 DNL-Worker/1.0";

function isNavigationTimeout(error: unknown) {
  return (
    error instanceof Error &&
    (error.message.includes("page.goto: Timeout") ||
      error.message.toLowerCase().includes("navigation timeout"))
  );
}

async function waitForBestEffortPageStability(page: Page) {
  try {
    await page.waitForLoadState("load", {
      timeout: LOAD_STATE_TIMEOUT_MS,
    });
  } catch {
    // Some sites keep loading ads/trackers forever. We still want the current visual state.
  }

  await page.waitForTimeout(STABILIZATION_DELAY_MS);
}

async function detectExplicitAccessBlock(page: Page) {
  const text = await page
    .locator("body")
    .innerText({
      timeout: 2_000,
    })
    .catch(() => "");
  const normalized = text.toLowerCase();
  const blockedSignals = [
    "captcha",
    "access denied",
    "paywall",
    "assine para continuar",
    "conteudo exclusivo para assinantes",
    "verifique que voce",
    "verify you are human",
  ];

  if (blockedSignals.some((signal) => normalized.includes(signal))) {
    throw new ExternalServiceError(
      "Site blocked automated evidence capture with login, paywall, CAPTCHA, or access control",
      "screenshot_access_blocked",
      false,
    );
  }
}

async function expandContinueReadingBlocks(page: Page) {
  const labels = [
    "Continuar lendo",
    "Continue lendo",
    "Ler mais",
    "Leia mais",
    "Mostrar mais",
    "Carregar mais",
  ];

  for (const label of labels) {
    const locator = page.getByText(label, { exact: false }).first();

    if ((await locator.count().catch(() => 0)) === 0) {
      continue;
    }

    try {
      await locator.scrollIntoViewIfNeeded({
        timeout: 3_000,
      });
      await locator.click({
        timeout: 3_000,
      });
      await page.waitForTimeout(STABILIZATION_DELAY_MS);
    } catch {
      // Some pages expose the text inside non-clickable wrappers. Keep the screenshot best-effort.
    }
  }
}

export async function captureScreenshot(url: string): Promise<ScreenshotResult> {
  const browser = await chromium.launch({
    headless: true,
  });

  try {
    const context = await browser.newContext({
      viewport: {
        width: 1440,
        height: 1200,
      },
      userAgent: USER_AGENT,
      locale: "pt-BR",
      timezoneId: "America/Sao_Paulo",
      extraHTTPHeaders: {
        "accept-language": "pt-BR,pt;q=0.9,en-US;q=0.7,en;q=0.6",
      },
    });
    const page = await context.newPage();

    await page.setDefaultNavigationTimeout(PAGE_TIMEOUT_MS);
    await page.setDefaultTimeout(PAGE_TIMEOUT_MS);

    try {
      const response = await page.goto(url, {
        timeout: PRIMARY_NAVIGATION_TIMEOUT_MS,
        waitUntil: "domcontentloaded",
      });
      if (response && response.status() >= 400) {
        throw new ExternalServiceError(
          `Site returned HTTP ${response.status()} during screenshot capture`,
          "screenshot_http_error",
          response.status() === 429 || response.status() >= 500,
        );
      }
    } catch (error) {
      if (!isNavigationTimeout(error)) {
        throw error;
      }
    }

    await waitForBestEffortPageStability(page);
    await detectExplicitAccessBlock(page);
    await expandContinueReadingBlocks(page);
    await waitForBestEffortPageStability(page);

    let buffer: Buffer;

    try {
      buffer = await page.screenshot({
        type: "png",
        fullPage: true,
      });
    } catch {
      buffer = await page.screenshot({
        type: "png",
        fullPage: false,
      });
    }

    return {
      buffer,
      finalUrl: page.url(),
      capturedAt: new Date().toISOString(),
    };
  } catch (error) {
    if (error instanceof ExternalServiceError) {
      throw error;
    }
    throw new ExternalServiceError(
      error instanceof Error ? error.message : "Failed to capture screenshot",
      "screenshot_capture_failed",
      true,
    );
  } finally {
    await browser.close();
  }
}
