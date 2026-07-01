export interface StartBody {
  siteID: string;
  gitRemote: string;
  gitRef: string;
  token: string;
}

export interface StopBody {
  siteID: string;
}

export interface StatusBody {
  siteID: string;
}

export interface StartResponse {
  previewURL: string;
  mcpURL: string;
}

export interface StatusResponse {
  siteID: string;
  previewReady: boolean;
  mcpReady: boolean;
}
