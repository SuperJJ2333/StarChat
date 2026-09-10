"""Protected deposit repair API client; never connects to a database.

Set STARCHAT_ADMIN_TOKEN to a real admin access token whose wallet grant is valid.
No command prints credentials or complete wallet addresses. No command is retried.
With no subcommand, prints help without network IO. Preview records review evidence
but does not change balances. Use the admin UI to inspect complete addresses.

Example (substitute actual values; do not put tokens on the command line):
  py -3.12 scripts/admin_deposit_repair.py --base-url https://admin.example candidates --txid <hash> --log-index 0
  ... preview --receipt-id <id> --intent-id <id> --reason-code EXPIRED_INTENT_REVIEW --reason-detail <reason>
  ... execute --preview-id <id> --digest <digest> --expected-version 1 --operation-id <stable-id> --confirm
  ... status --operation-id <same-stable-id>

Keep the operation ID before executing; it is also the Idempotency-Key. On an
unknown result, query status. Never generate a new ID to retry an unknown write.
Exit codes: 0 success/help; 2 rejected/configuration; 3 unknown execute result.
"""
import argparse
import json
import os
import re
from urllib.parse import urlsplit

import httpx


def patterned(pattern):
    def parse(value):
        if not re.fullmatch(pattern, value):
            raise argparse.ArgumentTypeError('Invalid value format')
        return value
    return parse


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('Expected a positive integer')
    return number


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError('Expected a nonnegative integer')
    return number


def parser():
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    result.add_argument('--base-url', default=os.environ.get('STARCHAT_ADMIN_URL'))
    commands = result.add_subparsers(dest='command')
    candidates = commands.add_parser('candidates', help='Read candidates for an incoming chain event')
    candidates.add_argument('--txid', required=True, type=patterned('[a-f0-9]{64}'))
    candidates.add_argument('--log-index', required=True, type=nonnegative)
    candidates.add_argument('--query')
    preview = commands.add_parser('preview', help='Create review evidence; no balance change')
    preview.add_argument('--receipt-id', required=True)
    preview.add_argument('--intent-id', required=True)
    preview.add_argument('--reason-code', required=True, choices=['CLOCK_ORDERING_REVIEW',
        'EXPIRED_INTENT_REVIEW', 'ATTRIBUTION_CORRECTION', 'PAYMENT_BEFORE_ORDER', 'OTHER'])
    preview.add_argument('--reason-detail', required=True)
    preview.add_argument('--payment-attestation', action='store_true', help='Explicitly attest payment belongs to this order')
    status = commands.add_parser('status', help='Read an operation result; never replay')
    status.add_argument('--operation-id', required=True, type=patterned('[A-Za-z0-9-]{1,36}'))
    execute = commands.add_parser('execute', help='Apply a reviewed preview through protected API')
    execute.add_argument('--preview-id', required=True)
    execute.add_argument('--digest', required=True, type=patterned('[a-f0-9]{64}'))
    execute.add_argument('--expected-version', required=True, type=positive)
    execute.add_argument('--operation-id', required=True, type=patterned('[A-Za-z0-9-]{1,36}'))
    execute.add_argument('--confirm', required=True, action='store_true', help='Confirm reviewed user/order/amount/address evidence')
    return result


def safe_output(value, token):
    # Outputs may be redirected to verification logs: mask addresses everywhere,
    # including free text, and never emit a reflected bearer token.
    encoded = json.dumps(value, ensure_ascii=False)
    if token:
        encoded = encoded.replace(token, '[REDACTED]')
    encoded = re.sub(r'T[1-9A-HJ-NP-Za-km-z]{33}', '[WALLET_ADDRESS]', encoded)
    print(encoded)


def main(argv=None, *, client_factory=httpx.Client):
    cli = parser()
    args = cli.parse_args(argv)
    if args.command is None:
        cli.print_help()
        return 0
    token = os.environ.get('STARCHAT_ADMIN_TOKEN', '').strip()
    try:
        url = urlsplit(args.base_url or '')
        valid = (url.scheme == 'https' and url.hostname and not url.username and not url.password
            and not url.query and not url.fragment and url.path in {'', '/'})
    except ValueError:
        valid = False
    if not valid or not token or any(c in token for c in '\r\n'):
        safe_output({'error': 'HTTPS_OR_TOKEN_CONFIGURATION_REQUIRED'}, '')
        return 2
    endpoint = args.base_url.rstrip('/') + '/api/v1/admin/wallet/manual/deposit-repairs'
    headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/json'}
    method, params, body = 'GET', None, None
    if args.command == 'candidates':
        endpoint += '/candidates'
        params = {'txid': args.txid, 'log_index': args.log_index}
        if args.query:
            params['query'] = args.query
    elif args.command == 'status':
        endpoint += '/' + args.operation_id
    elif args.command == 'preview':
        method, endpoint = 'POST', endpoint + '/preview'
        body = {key: getattr(args, key) for key in ('receipt_id', 'intent_id', 'reason_code', 'reason_detail', 'payment_attestation')}
    else:
        method = 'POST'
        body = {key: getattr(args, key) for key in ('preview_id', 'digest', 'expected_version', 'operation_id')}
        body['confirmed'] = True
        headers['Idempotency-Key'] = args.operation_id
    try:
        with client_factory(verify=True, follow_redirects=False, trust_env=False, timeout=20.0) as client:
            response = client.request(method, endpoint, headers=headers, params=params, json=body)
        if response.status_code >= 500 and args.command == 'execute':
            raise httpx.ReadError('Unknown server result')
        if not response.is_success:
            # Do not print server error text that may reflect secrets/addresses.
            safe_output({'error': 'API_REJECTED', 'http_status': response.status_code,
                'operation_id': getattr(args, 'operation_id', None)}, token)
            return 2
        result = response.json()
    except (httpx.HTTPError, ValueError, OSError):
        unknown = args.command == 'execute'
        safe_output({'error': 'UNKNOWN_RESULT' if unknown else 'REQUEST_FAILED',
            'operation_id': getattr(args, 'operation_id', None),
            'next_step': 'status with the same operation ID; do not replay' if unknown else 'retry read or preview'}, token)
        return 3 if unknown else 2
    safe_output(result, token)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
