<?php
declare(strict_types=1);
require $argv[1] . '/config-manager-standalone/lib/desired_state.php';

$sha1 = str_repeat('a', 40);
$sha2 = str_repeat('b', 40);

$doc = ds_validate_document([
  'schema_version'=>1,
  'policies'=>[
    'mail-prod'=>[
      'enabled'=>true,
      'deployment'=>'postfix-prod',
      'selector'=>['groups'=>['mail'],'labels'=>['env'=>'prod','role'=>'mailrelay']],
      'desired'=>['type'=>'commit','value'=>$sha1],
      'enforcement'=>'manual',
      'max_targets'=>20,
    ],
    'mail-tag'=>[
      'enabled'=>true,
      'deployment'=>'postfix-prod',
      'selector'=>['groups'=>['mail']],
      'desired'=>['type'=>'tag','value'=>'v1.2.3'],
      'enforcement'=>'check_only',
    ],
  ]
]);

assert($doc['policies']['mail-prod']['desired']['value'] === $sha1);
assert(ds_server_matches(
  ['groups'=>['mail','prod'],'labels'=>['env'=>'prod','role'=>'mailrelay']],
  $doc['policies']['mail-prod']
) === true);
assert(ds_server_matches(
  ['groups'=>['mail'],'labels'=>['env'=>'lab','role'=>'mailrelay']],
  $doc['policies']['mail-prod']
) === false);

$releaseDoc = ['releases'=>[
  ['commit'=>$sha1,'tags'=>['v1.0.0']],
  ['commit'=>$sha2,'tags'=>['v1.2.3','stable']],
]];
assert(ds_resolve_tag_commit($releaseDoc,'v1.2.3') === $sha2);
assert(ds_resolve_tag_commit($releaseDoc,'missing') === null);

assert(ds_compliance($sha1,$sha1) === 'compliant');
assert(ds_compliance($sha1,$sha2) === 'drift');
assert(ds_compliance(null,$sha2) === 'not_installed');
assert(ds_compliance($sha1,null) === 'desired_unknown');
assert(ds_compliance($sha1,$sha1,'x') === 'error');

$summary=ds_summary([
  ['compliance'=>'compliant'],['compliance'=>'drift'],['compliance'=>'drift'],
  ['compliance'=>'not_installed'],['compliance'=>'error']
]);
assert($summary['total']===5 && $summary['compliant']===1 && $summary['drift']===2 && $summary['not_installed']===1 && $summary['error']===1);

$failed=false;
try {
  ds_validate_document(['schema_version'=>1,'policies'=>[
    'bad'=>[
      'enabled'=>true,'deployment'=>'x',
      'selector'=>['groups'=>['../root']],
      'desired'=>['type'=>'allowed_ref']
    ]
  ]]);
} catch (InvalidArgumentException $e) {$failed=true;}
assert($failed);


$tmpDir=sys_get_temp_dir().'/teko-ds-save-'.bin2hex(random_bytes(4));
mkdir($tmpDir,0700,true);
$tmpFile=$tmpDir.'/desired_state.json';
ds_atomic_save($tmpFile,$doc);
$round=json_decode(file_get_contents($tmpFile),true);
assert(is_array($round) && $round['schema_version']===1 && isset($round['policies']['mail-prod']));
assert((fileperms($tmpFile)&0777)===0640);

$real=$tmpDir.'/real.json';
file_put_contents($real,'{}');
$link=$tmpDir.'/link.json';
symlink($real,$link);
$symlinkRejected=false;
try { ds_atomic_save($link,$doc); } catch (RuntimeException $e) { $symlinkRejected=true; }
assert($symlinkRejected===true);

@unlink($link);
@unlink($real);
@unlink($tmpFile);
@rmdir($tmpDir);


// Multi-source schema: Config Manager source.
$cmDoc = ds_validate_document([
  'schema_version'=>1,
  'policies'=>[
    'monit-base'=>[
      'enabled'=>true,
      'description'=>'Monit baseline',
      'source'=>[
        'type'=>'config_manager',
        'reference_server'=>'teko',
        'source_config'=>'monit-teko',
        'target_config'=>'monit-teko'
      ],
      'selector'=>['groups'=>['linux'],'labels'=>['env'=>'prod']],
      'enforcement'=>'manual',
      'max_targets'=>25
    ]
  ]
]);
$cm=$cmDoc['policies']['monit-base'];
assert($cm['source']['type']==='config_manager');
assert($cm['source']['reference_server']==='teko');
assert($cm['source']['source_config']==='monit-teko');
assert($cm['source']['target_config']==='monit-teko');
assert($cm['desired']['type']==='config_hash');
assert($cm['deployment']==='');

// New structured Git source.
$gitDoc = ds_validate_document([
  'schema_version'=>1,
  'policies'=>[
    'scripts'=>[
      'enabled'=>true,
      'source'=>[
        'type'=>'git',
        'deployment'=>'scripts',
        'desired'=>['type'=>'tag','value'=>'v1.2.3']
      ],
      'selector'=>['groups'=>['linux']],
      'enforcement'=>'manual'
    ]
  ]
]);
assert($gitDoc['policies']['scripts']['source']['type']==='git');
assert($gitDoc['policies']['scripts']['deployment']==='scripts');
assert($gitDoc['policies']['scripts']['desired']['type']==='tag');

// Invalid config-manager config id is rejected.
$bad=false;
try {
  ds_validate_document([
    'schema_version'=>1,
    'policies'=>[
      'badcm'=>[
        'source'=>[
          'type'=>'config_manager',
          'reference_server'=>'teko',
          'source_config'=>'../../etc/shadow',
          'target_config'=>'x'
        ],
        'selector'=>[],
        'enforcement'=>'manual'
      ]
    ]
  ]);
} catch (InvalidArgumentException $e) {$bad=true;}
assert($bad===true);


// Canary rollout partition and limits.
$canaryDoc=ds_validate_document([
  'schema_version'=>1,
  'policies'=>[
    'canary-test'=>[
      'enabled'=>true,
      'source'=>['type'=>'git','deployment'=>'scripts','desired'=>['type'=>'tag','value'=>'v1.0.0']],
      'selector'=>['groups'=>['linux'],'labels'=>['env'=>'prod']],
      'enforcement'=>'manual',
      'max_targets'=>10,
      'rollout'=>[
        'strategy'=>'canary',
        'canary_selector'=>['groups'=>['canary']],
        'max_canary_targets'=>2,
        'require_canary_compliant'=>true
      ]
    ]
  ]
]);
$cp=$canaryDoc['policies']['canary-test'];
assert($cp['rollout']['strategy']==='canary');
$fleet=[
  0=>['name'=>'a','groups'=>['linux','canary'],'labels'=>['env'=>'prod']],
  1=>['name'=>'b','groups'=>['linux'],'labels'=>['env'=>'prod']],
  2=>['name'=>'c','groups'=>['linux'],'labels'=>['env'=>'prod']],
];
$part=ds_rollout_partition($fleet,$cp);
assert(array_keys($part['canary'])===[0]);
assert(array_keys($part['remaining'])===[1,2]);

$badCanary=false;
try {
  ds_validate_document([
    'schema_version'=>1,
    'policies'=>[
      'bad-canary'=>[
        'source'=>['type'=>'git','deployment'=>'x','desired'=>['type'=>'allowed_ref']],
        'selector'=>['groups'=>['linux']],
        'rollout'=>['strategy'=>'canary','canary_selector'=>[]]
      ]
    ]
  ]);
} catch (InvalidArgumentException $e) {$badCanary=true;}
assert($badCanary===true);

echo "desired_state_logic_test: OK\n";
