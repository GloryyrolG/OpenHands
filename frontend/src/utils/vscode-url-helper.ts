/**
 * Helper function to transform VS Code URLs
 *
 * This function checks if a VS Code URL points to localhost and replaces it with
 * the current window's hostname if they don't match.
 *
 * @param vsCodeUrl The original VS Code URL from the backend
 * @returns The transformed URL with the correct hostname
 */
export function transformVSCodeUrl(vsCodeUrl: string | null): string | null {
  if (!vsCodeUrl) return null;

  try {
    const url = new URL(vsCodeUrl);

    // Check if the URL points to localhost
    if (
      url.hostname === "localhost" &&
      window.location.hostname !== "localhost"
    ) {
      // [OH-MULTI] Convert to relative sandbox-port proxy URL so it's same-origin
      // and same-protocol as the parent page (avoids cross-origin iframe warning).
      // e.g. http://localhost:56025/?tkn=xxx → /api/sandbox-port/56025/?tkn=xxx
      if (url.port) {
        return `/api/sandbox-port/${url.port}${url.pathname}${url.search}`;
      }
      // Fallback: replace hostname + fix protocol
      url.hostname = window.location.hostname;
      url.protocol = window.location.protocol;
      return url.toString();
    }

    return vsCodeUrl;
  } catch {
    // Silently handle the error and return the original URL
    return vsCodeUrl;
  }
}
