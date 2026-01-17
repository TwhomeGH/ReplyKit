// server.js
const http = require('http');
const fs = require('fs');

const path = require('path');


const PORT = 3000;

/*
To generate a self-signed certificate for testing purposes, you can use the following OpenSSL command:
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem \
  -out cert.pem \
  -days 365
*/

// let key = path.join(__dirname, 'cert', 'key.pem')
// let cert = path.join(__dirname, 'cert', 'cert.pem')

// const options = {

//     key: fs.readFileSync(key),
//     cert: fs.readFileSync(cert)

// };

/*
If you want to use HTTPS, uncomment the following line and comment out the next one.
And Then you well need to fix the certificate file path above.

Change:
    const server = http.createServer(options, (req, res) => {   
    ...
    };
*/

const server = http.createServer( (req, res) => {

    
    if (req.method === 'POST' && req.url === '/post') {
        let body = '';

        req.on('data', chunk => {
            body += chunk.toString();
        });

        req.on('end', () => {
            try {
                const data = JSON.parse(body);

                //console.log(data)
                // console.log(Array.isArray(data.logs))

                var title = '';
                var bodyText = '';
                var time = '';

                
                if (Array.isArray(data.logs)) {
                    // data 是陣列
                    console.log("Array of objects:", data.logs.length);


                   const logsText = (Array.isArray(data.logs) ? data.logs : [data.logs])
                        .map(e => `${e.time}: ${e.title}: ${e.body}`)
                        .join('\n');

                    console.log(logsText);


                } else if (data && typeof data === "object") {
                    // data 是單個物件
                    //console.log("Single object:", data);
                    title = data.title
                    bodyText = data.body
                    time = data.time

                    console.log('R\n',data)
                    console.log(time, ':', title, ':', bodyText);

                } else {
                    // 其他型別（通常不會發生）
                    console.warn("Unexpected data type:", typeof data);
                }



                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'ok', received: { title, body: bodyText } }));
            } catch (err) {
                console.error('Invalid JSON', err);
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'error', message: 'Invalid JSON' }));
            }
        });

    } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'error', message: 'Not Found' }));
    }
});

server.listen(PORT, () => {
    console.log(`Server running on https://localhost:${PORT}`);
});