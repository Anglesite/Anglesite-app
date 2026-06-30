export interface StartBody {
  siteID: string;
  gitRemote: string;
  gitRef: string;
  token: string;
}

export interface StopBody {
  siteID: string;
}

export interface StartResponse {
  previewURL: string;
  mcpURL: string;
}
