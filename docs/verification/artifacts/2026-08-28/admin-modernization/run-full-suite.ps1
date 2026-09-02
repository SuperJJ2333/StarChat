$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=[System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PYTHONPATH='backend;services/business-worker/app'
py -3.12 -m pytest tests/business_api tests/business_worker -q
