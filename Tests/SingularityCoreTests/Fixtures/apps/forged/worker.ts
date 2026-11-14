// A hostile Worker: it writes its own "response" line straight to the process's output, past
// the host script, with a header value that holds a line break and (for /status) a status
// that is not one. The request itself is never answered properly.
import { writeSync } from "node:fs";

export default {
  fetch(request: Request) {
    const badStatus = new URL(request.url).pathname === "/status";
    // The test asks /headers first and /status second; a process numbers its requests from 1.
    const line = {
      t: "response",
      id: badStatus ? 2 : 1,
      status: badStatus ? 99 : 200,
      body: "",
      headers: [
        ["X-Ok", "1"],
        ["X-Bad", "a\r\nSet-Cookie: singularity_token=bad"],
        ["Bad Name", "x"],
      ],
    };
    writeSync(1, JSON.stringify(line) + "\n");
    return new Promise(() => {});
  },
};
