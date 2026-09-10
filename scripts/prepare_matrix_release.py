#!/usr/bin/env python3
"""Stage a narrow Matrix release without writing to the running deployment.

Requires PyYAML. Output must be a new directory outside root/source. All inputs
are local; this tool neither builds images nor contacts Docker or SSH.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

import yaml


class Refused(Exception):
    """Safe, non-secret diagnostic."""


def read(root, relative):
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise Refused('input path escapes its root')
    return path.read_text(encoding='utf-8')


def validate_main(existing, candidate):
    old, new = copy.deepcopy(existing), copy.deepcopy(candidate)
    for value in (old, new):
        for key in ('listeners', 'presence', 'rc_invites', 'redis'):
            value.pop(key, None)
        value['database']['args'].pop('cp_max', None)
    if old != new:
        raise Refused('main configuration drift outside the approved change set')
    replication = {'port': 9093, 'bind_addresses': ['0.0.0.0'], 'tls': False,
                   'type': 'http', 'resources': [{'names': ['replication']}]}
    old_list = list(existing['listeners'])
    new_list = list(candidate['listeners'])
    if replication not in new_list:
        raise Refused('main configuration drift: replication listener missing')
    if replication in old_list:
        old_list.remove(replication)
    new_list.remove(replication)
    if old_list != new_list or any(item.get('port') == 9093 for item in old_list):
        raise Refused('main configuration drift: existing listeners changed')


def nginx_block(text, header):
    # Approved snippets contain no nested blocks. Anchoring complete directive
    # lines avoids matching comments or replacing unrelated server content.
    pattern = re.compile(r'(?m)^[ \t]*' + re.escape(header) + r'[ \t]*\{[^{}]*\}')
    return list(pattern.finditer(text))


def patch_nginx(existing, source):
    pairs = (
        ('upstream synapse_sync_upstream', 'upstream synapse_upstream'),
        ('location ~ ^/_matrix/client/(r0|v3)/(sync|events)$', 'location /_matrix/'),
    )
    for header, anchor in pairs:
        blocks = nginx_block(source, header)
        if len(blocks) != 1:
            raise Refused('nginx source snippet is missing or ambiguous')
        snippet = blocks[0].group()
        matches = nginx_block(existing, header)
        if matches:
            if len(matches) != 1 or matches[0].group().strip() != snippet.strip():
                raise Refused('nginx existing sync snippet mismatches source')
            continue
        # A partial or differently formatted sync directive requires review.
        marker = 'synapse_sync_upstream' if header.startswith('upstream') else '(sync|events)'
        if marker in existing:
            raise Refused('nginx existing sync directive is ambiguous')
        anchors = nginx_block(existing, anchor)
        if len(anchors) != 1:
            raise Refused('nginx insertion anchor missing or ambiguous')
        position = anchors[0].start()
        existing = existing[:position] + snippet + '\n\n' + existing[position:]
    return existing


def compose_candidate(existing, source, image):
    result = copy.deepcopy(existing)
    services = result['services']
    wanted = source['services']
    services['postgres']['command'] = ['postgres', '-N', '250']
    main = services['synapse']
    if 'build' in main:
        raise Refused('existing synapse build directive requires explicit removal before staging')
    main['image'] = image
    dependencies = main.setdefault('depends_on', {})
    if isinstance(dependencies, list):
        dependencies = {name: {'condition': 'service_started'} for name in dependencies}
        main['depends_on'] = dependencies
    dependencies['matrix-redis'] = copy.deepcopy(wanted['synapse']['depends_on']['matrix-redis'])
    environment = main.setdefault('environment', {})
    if isinstance(environment, list):
        raise Refused('existing synapse environment must use mapping form')
    for name in ('CHATFLOW_MEDIA_DEDUP', 'CHATFLOW_MEDIA_RETENTION_MS'):
        environment[name] = wanted['synapse']['environment'][name]
    main['healthcheck'] = copy.deepcopy(wanted['synapse']['healthcheck'])
    for name in ('matrix-redis', 'synapse-sync-worker'):
        service = copy.deepcopy(wanted[name])
        service.pop('build', None)
        if name == 'synapse-sync-worker':
            service['image'] = image
        if name in services and services[name] != service:
            raise Refused('existing worker or Redis service mismatches candidate')
        services[name] = service
    return yaml.safe_dump(result, sort_keys=False, allow_unicode=True)


def prepare(root, source, output, image):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._:/-]*:[a-zA-Z0-9_][a-zA-Z0-9_.-]*', image) or image.rsplit(':', 1)[1].lower() == 'latest':
        raise Refused('an explicit release image tag is required; latest is forbidden')
    root, source, output = (Path(path).resolve() for path in (root, source, output))
    if output.exists() or any(output.is_relative_to(p) or p.is_relative_to(output) for p in (root, source)):
        raise Refused('output must be a new directory outside root and source')
    renderer_path = source / 'infra/render_config.py'
    read(source, 'infra/render_config.py')  # Reject symlink escape before import.
    spec = importlib.util.spec_from_file_location('release_renderer', renderer_path)
    renderer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(renderer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    read(root, '.env')
    values = renderer.parse_env(root / '.env')
    renderer.check_production_guards(values)
    files = {}
    for name in ('homeserver', 'worker-sync'):
        relative = f'infra/synapse/{name}.yaml.template'
        template = read(source, relative)
        files[relative] = template
        files[f'data/synapse/{name}.yaml'] = renderer.render(template, values)
    existing_main = yaml.safe_load(read(root, 'data/synapse/homeserver.yaml'))
    candidate_main = yaml.safe_load(files['data/synapse/homeserver.yaml'])
    validate_main(existing_main, candidate_main)
    worker = yaml.safe_load(files['data/synapse/worker-sync.yaml'])
    worker_db = copy.deepcopy(worker['database'])
    main_db = copy.deepcopy(candidate_main['database'])
    for database in (worker_db, main_db):
        database['args'].pop('cp_max', None)
    if worker_db != main_db:
        raise Refused('worker database identity differs from main')
    nginx_source = read(source, 'infra/nginx/nginx.conf.template')
    files['data/nginx/nginx.conf'] = patch_nginx(read(root, 'data/nginx/nginx.conf'), renderer.render(nginx_source, values))
    files['infra/nginx/nginx.conf.template'] = patch_nginx(read(root, 'infra/nginx/nginx.conf.template'), nginx_source)
    files['docker-compose.yml'] = compose_candidate(yaml.safe_load(read(root, 'docker-compose.yml')),
                                                   yaml.safe_load(read(source, 'docker-compose.yml')), image)
    hashes = {name: hashlib.sha256(content.encode('utf-8')).hexdigest() for name, content in sorted(files.items())}
    manifest = {'changed_files': sorted(files), 'sha256': hashes}
    files['manifest.json'] = json.dumps(manifest, indent=2) + '\n'
    output.mkdir(mode=0o700, parents=True)
    os.chmod(output, 0o700)
    for name, content in files.items():
        target = output / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for parent in target.parents:
            if parent == output.parent:
                break
            os.chmod(parent, 0o700)
        with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8', newline='') as handle:
            handle.write(content)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ('root', 'source', 'image', 'output'):
        parser.add_argument('--' + argument, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.root, args.source, args.output, args.image)
    except Refused as error:
        print('prepare_matrix_release: ' + str(error), file=sys.stderr)
        return 1
    except (Exception, SystemExit):
        # YAML/parser errors may embed credential-bearing source lines.
        print('prepare_matrix_release: input validation or staging failed (details suppressed)', file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
