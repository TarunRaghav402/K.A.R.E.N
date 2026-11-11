/**
 * Firebase Cloud Messaging (FCM) HTTP v1 Service for Cloudflare Workers.
 * Authenticates directly using Google Service Account RSA-SHA256 JWT via Web Crypto API.
 */

import { Env } from "../types";

let cachedAccessToken: { token: string; expiresAt: number } | null = null;

function base64UrlEncode(str: string): string {
  return btoa(str)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function base64UrlEncodeBuffer(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const cleanPem = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const binary = atob(cleanPem);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

export async function getGoogleOAuth2Token(env: Env): Promise<string | null> {
  if (!env.FCM_PROJECT_ID || !env.FCM_CLIENT_EMAIL || !env.FCM_PRIVATE_KEY) {
    return null;
  }

  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt > now + 60) {
    return cachedAccessToken.token;
  }

  try {
    const header = {
      alg: "RS256",
      typ: "JWT",
    };

    const claimSet = {
      iss: env.FCM_CLIENT_EMAIL,
      sub: env.FCM_CLIENT_EMAIL,
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
    };

    const encodedHeader = base64UrlEncode(JSON.stringify(header));
    const encodedClaimSet = base64UrlEncode(JSON.stringify(claimSet));
    const dataToSign = `${encodedHeader}.${encodedClaimSet}`;

    const keyBuffer = pemToArrayBuffer(env.FCM_PRIVATE_KEY);
    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyBuffer,
      {
        name: "RSASSA-PKCS1-v1_5",
        hash: { name: "SHA-256" },
      },
      false,
      ["sign"]
    );

    const encoder = new TextEncoder();
    const signatureBuffer = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      cryptoKey,
      encoder.encode(dataToSign)
    );

    const jwt = `${dataToSign}.${base64UrlEncodeBuffer(signatureBuffer)}`;

    // Exchange JWT for access token
    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    if (!tokenResponse.ok) {
      console.error(
        `Failed to obtain Google access token: ${tokenResponse.status} ${await tokenResponse.text()}`
      );
      return null;
    }

    const tokenData = (await tokenResponse.json()) as {
      access_token: string;
      expires_in: number;
    };
    cachedAccessToken = {
      token: tokenData.access_token,
      expiresAt: now + (tokenData.expires_in || 3600),
    };

    return cachedAccessToken.token;
  } catch (error) {
    console.error("Error creating Google OAuth2 token:", error);
    return null;
  }
}

export async function sendFCMNotification(
  env: Env,
  fcmToken: string,
  requestId: string,
  reqType: string,
  title: string,
  message: string,
  actions: string[],
  expiresAt: number,
  details?: string | null
): Promise<boolean> {
  const accessToken = await getGoogleOAuth2Token(env);
  if (!accessToken || !env.FCM_PROJECT_ID) {
    console.log(
      `[FCM Worker] Direct push mode (FCM credentials not active). Request ID: ${requestId}`
    );
    return false;
  }

  const url = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  const payload = {
    message: {
      token: fcmToken,
      notification: {
        title: title,
        body: message,
      },
      data: {
        request_id: requestId,
        type: reqType,
        title: title,
        message: message,
        details: details || "",
        actions: JSON.stringify(actions),
        expires_at: expiresAt.toString(),
      },
      android: {
        priority: "high",
        notification: {
          channel_id: "karen_requests",
          click_action: "KAREN_NOTIFICATION_CLICK",
          notification_priority: "PRIORITY_MAX",
        },
      },
    },
  };

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json; UTF-8",
      },
      body: JSON.stringify(payload),
    });

    if (response.ok) {
      return true;
    } else {
      console.error(
        `FCM API error (${response.status}): ${await response.text()}`
      );
      return false;
    }
  } catch (err) {
    console.error("Exception sending FCM notification:", err);
    return false;
  }
}

