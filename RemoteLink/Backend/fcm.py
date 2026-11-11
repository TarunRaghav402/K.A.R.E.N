"""Firebase Cloud Messaging (FCM) HTTP v1 dispatcher for K.A.R.E.N. Remote Link."""

from __future__ import annotations
import json
import time
import logging
from pathlib import Path
from typing import Optional, List, Dict, Any
import httpx

from .config import settings

logger = logging.getLogger("RemoteLink.FCM")


class FCMDispatcher:
    def __init__(self, service_account_path: Optional[str] = settings.fcm_service_account_path) -> None:
        self.service_account_path = service_account_path
        self._cached_token: Optional[str] = None
        self._token_expiry: float = 0.0
        self._project_id: Optional[str] = None
        self._load_service_account()

    def _load_service_account(self) -> None:
        if not self.service_account_path:
            logger.info("FCM service account not configured. Operating in WebSocket/Direct relay mode.")
            return

        path = Path(self.service_account_path)
        if not path.exists():
            logger.warning(f"FCM credentials file not found at {path}. Push notifications will use direct channel.")
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
                self._project_id = data.get("project_id")
                logger.info(f"Loaded FCM service account for project: {self._project_id}")
        except Exception as e:
            logger.error(f"Failed to load FCM service account: {e}")

    async def get_access_token(self) -> Optional[str]:
        """Obtains OAuth2 access token using Google Auth if available."""
        if not self.service_account_path or not self._project_id:
            return None

        now = time.time()
        if self._cached_token and now < self._token_expiry - 60:
            return self._cached_token

        try:
            # Try using google-auth if installed
            from google.oauth2 import service_account
            import google.auth.transport.requests

            scopes = ["https://www.googleapis.com/auth/firebase.messaging"]
            credentials = service_account.Credentials.from_service_account_file(
                self.service_account_path, scopes=scopes
            )
            request = google.auth.transport.requests.Request()
            credentials.refresh(request)
            self._cached_token = credentials.token
            self._token_expiry = now + 3600
            return self._cached_token
        except ImportError:
            logger.warning(
                "google-auth package not installed. Install via `pip install google-auth` for FCM HTTP v1 authorization."
            )
            return None
        except Exception as e:
            logger.error(f"Error obtaining FCM access token: {e}")
            return None

    async def send_notification(
        self,
        fcm_token: str,
        request_id: str,
        req_type: str,
        title: str,
        message: str,
        actions: List[str],
        expires_at: float,
        details: Optional[str] = None,
    ) -> bool:
        """Dispatches an FCM message to an Android device."""
        if not fcm_token:
            return False

        token = await self.get_access_token()
        if not token or not self._project_id:
            logger.info(
                f"[FCM Mock/Dev] Would send FCM to {fcm_token[:10]}...: '{title}' - '{message}' Actions: {actions}"
            )
            return True

        url = f"https://fcm.googleapis.com/v1/projects/{self._project_id}/messages:send"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; UTF-8",
        }

        # Data payload enables background handling and direct action execution on Android
        payload: Dict[str, Any] = {
            "message": {
                "token": fcm_token,
                "notification": {
                    "title": title,
                    "body": message,
                },
                "data": {
                    "request_id": request_id,
                    "type": req_type,
                    "title": title,
                    "message": message,
                    "details": details or "",
                    "actions": json.dumps(actions),
                    "expires_at": str(expires_at),
                },
                "android": {
                    "priority": "high",
                    "notification": {
                        "channel_id": "karen_requests",
                        "click_action": "KAREN_NOTIFICATION_CLICK",
                        "notification_priority": "PRIORITY_MAX",
                    },
                },
            }
        }

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(url, headers=headers, json=payload)
                if resp.status_code == 200:
                    logger.info(f"FCM notification sent successfully for request {request_id}")
                    return True
                else:
                    logger.error(f"FCM error ({resp.status_code}): {resp.text}")
                    return False
        except Exception as e:
            logger.error(f"Exception sending FCM notification: {e}")
            return False

