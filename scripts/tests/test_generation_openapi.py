import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
try:
    from fastapi import FastAPI
    AVAILABLE=True
except ImportError:AVAILABLE=False
from nativ_generation.api import install_routes
from nativ_generation.openapi import install_openapi

@unittest.skipUnless(AVAILABLE,'Requires the managed FastAPI runtime')
class GenerationOpenAPITests(unittest.TestCase):
    def setUp(self):
        self.app=FastAPI()
        @self.app.get('/existing')
        def existing():return {'preserved':True}
        install_routes(self.app,lambda:None,api_key='fixture')
        self.before=copy.deepcopy(self.app.openapi())
        install_openapi(self.app);self.schema=self.app.openapi()
    def test_preserves_base_contract_and_is_idempotent(self):
        self.assertEqual(self.schema['paths']['/existing'],self.before['paths']['/existing'])
        install_openapi(self.app);self.assertIs(self.schema,self.app.openapi())
        self.assertEqual(self.schema['info'],self.before['info'])
    def test_all_mutations_have_store_precondition_and_generation_key(self):
        count=0
        for path,item in self.schema['paths'].items():
            if not path.startswith(('/v1/music/','/v1/video/')):continue
            for method,operation in item.items():
                if method not in ('get','head','post','put','patch','delete'):continue
                self.assertIn({'NativGenerationBearer':[]},operation['security'])
                headers={p['name']:p for p in operation.get('parameters',[]) if p.get('in')=='header'}
                if method in ('post','put','patch','delete'):
                    count+=1;self.assertTrue(headers['X-Nativ-Store-ID']['required']);self.assertIn('428',operation['responses'])
                if method=='post' and path.endswith('/generations'):
                    self.assertTrue(headers['Idempotency-Key']['required']);self.assertIn('202',operation['responses'])
                    self.assertIn('requestBody',operation)
        self.assertGreater(count,20)
    def test_binary_head_range_stream_and_upload_are_not_untyped_json(self):
        content=self.schema['paths']['/v1/video/assets/{asset_id}/content']
        self.assertIn('head',content);self.assertIn('206',content['get']['responses']);self.assertIn('416',content['get']['responses'])
        self.assertIn('video/mp4',content['get']['responses']['200']['content'])
        events=self.schema['paths']['/v1/music/generations/{job_id}/events']['get']
        self.assertIn('text/event-stream',events['responses']['200']['content'])
        upload=self.schema['paths']['/v1/video/inputs']['post']['requestBody']['content']['multipart/form-data']
        self.assertEqual(upload['schema']['required'],['file']);self.assertEqual(upload['schema']['properties']['file']['format'],'binary')
    def test_profile_requests_preserve_unsupported_and_unknown_fields(self):
        schemas=self.schema['components']['schemas']
        video=schemas['NativVideoGenerationRequest'];music=schemas['NativMusicGenerationRequest']
        self.assertEqual(video['discriminator']['propertyName'],'model');self.assertGreater(len(video['oneOf']),5)
        self.assertEqual(music['discriminator']['propertyName'],'model')
        runway=schemas[video['discriminator']['mapping']['runway-gen4.5'].split('/')[-1]]
        self.assertTrue(runway['properties']['allow_remote']['const']);self.assertFalse(runway['additionalProperties'])
        self.assertEqual(runway['properties']['audio_mode']['enum'],['silent']);self.assertEqual(runway['properties']['fps']['const'],None)
        h3=schemas[video['discriminator']['mapping']['minimax-h3-local'].split('/')[-1]]
        self.assertEqual(h3['properties']['audio_mode']['enum'],['native_generated'])
    def test_refs_resolve_and_new_control_routes_have_typed_responses(self):
        def visit(value):
            if isinstance(value,dict):
                if '$ref' in value and value['$ref'].startswith('#/components/schemas/'):
                    self.assertIn(value['$ref'].split('/')[-1],self.schema['components']['schemas'])
                for child in value.values():visit(child)
            elif isinstance(value,list):
                for child in value:visit(child)
        visit(self.schema);json.dumps(self.schema,allow_nan=False)
        for path in ('server-state','prepare-stop','configuration','runtimes'):
            op=self.schema['paths']['/v1/video/'+path]['post' if path=='prepare-stop' else 'get']
            response=op['responses']['202' if path=='prepare-stop' else '200']
            self.assertIn('$ref',response['content']['application/json']['schema'])
        transform=self.schema['paths']['/v1/video/inputs/{input_id}/transform']['post']
        self.assertIn('requestBody',transform)

    def test_duration_options_are_actual_provider_controls_not_request_fields(self):
        from nativ_video.catalog import profiles
        from nativ_video.providers import build_provider
        from nativ_generation.contracts import ProviderServices
        mapping=self.schema['components']['schemas']['NativVideoGenerationRequest']['discriminator']['mapping']
        for profile in profiles():
            if profile['deployment']=='local':continue
            provider=build_provider(profile,ProviderServices())
            schema=self.schema['components']['schemas'][mapping[profile['id']].split('/')[-1]]
            self.assertNotIn('duration_options',schema['properties'])
            for preset_id,preset in profile['capabilities']['presets'].items():
                for duration in preset['duration_options']:
                    request={'model':profile['id'],'prompt':'boat','allow_remote':True,'output_preset':preset_id,'duration':duration,'operation':preset.get('operation','text_to_video')}
                    if request['operation']=='image_to_video':request['inputs']=[{'input_id':'input','role':'first_frame'}]
                    self.assertEqual(provider.normalize(request)['duration'],duration)
    def test_copyable_docs_supply_store_precondition_for_every_mutation(self):
        root=Path(__file__).resolve().parents[2]
        for document in ('music.md','video.md'):
            content=(root/'Docs/api'/document).read_text();self.assertNotIn('127.0.0.1:8080',content)
            lines=iter(content.splitlines())
            for line in lines:
                if not line.startswith('curl '):continue
                command=line
                while command.rstrip().endswith('\\'):
                    command=command.rstrip()[:-1]+next(lines)
                if any(value in command for value in ('-X POST','-X PUT','-X PATCH','-X DELETE',' -d ')):
                    self.assertIn('X-Nativ-Store-ID: $NATIV_STORE_ID',command)
