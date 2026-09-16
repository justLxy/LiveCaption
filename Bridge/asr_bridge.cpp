#include <nemo_speech/asr.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>
static void check(nemo_speech_asr_status s) { if(s != NEMO_SPEECH_ASR_OK) { fprintf(stderr,"ASR: %s\n",nemo_speech_asr_last_error()); exit(2); } }
static std::string quote(const char* s) { std::string o="\""; for(const unsigned char* p=(const unsigned char*)s;*p;++p) { if(*p=='"'||*p=='\\') {o+='\\';o+=*p;} else if(*p<32){char b[8];snprintf(b,8,"\\u%04x",*p);o+=b;}else o+=*p; }return o+'"'; }
static unsigned long long utterance = 0;
static void drain(nemo_speech_asr_stream* stream) {
    for (;;) {
        nemo_speech_asr_result* result = nullptr;
        check(nemo_speech_asr_stream_next(stream, &result));
        if (!result) break;
        const bool final = nemo_speech_asr_result_is_final(result);
        const bool has_text = nemo_speech_asr_result_alternative_count(result) > 0;
        // Do not deduplicate: next() reports actual decoder updates. Swift needs
        // unchanged hypotheses with advancing audio to establish prefix stability.
        if (has_text || final) {
            const char* text = has_text ? nemo_speech_asr_result_transcript(result, 0) : "";
            printf("{\"type\":\"%s\",\"utterance\":%llu,\"text\":%s,\"audio\":%.3f}\n",
                   final ? "final" : "partial", utterance, quote(text).c_str(),
                   nemo_speech_asr_result_audio_processed(result));
            fflush(stdout);
        }
        if (final) ++utterance;
        nemo_speech_asr_result_destroy(result);
    }
}
int main(int argc,char**argv) {
 if(argc!=2){fprintf(stderr,"Usage: asr-bridge MODEL.gguf < mono-f32le-16000\n");return 1;}
 nemo_speech_asr_backend_config backend{sizeof(backend),0};
 nemo_speech_asr_model_config model{sizeof(model),argv[1],nullptr};
 nemo_speech_asr_streaming_config streaming{sizeof(streaming),1.0f,0,0,1};
 nemo_speech_asr_endpointing_config endpoint{sizeof(endpoint),true,false,800};
 nemo_speech_asr_recognizer_config cfg{};cfg.size=sizeof(cfg);cfg.backend=&backend;cfg.model=&model;cfg.streaming=&streaming;cfg.endpointing=&endpoint;
 nemo_speech_asr_recognizer* rec=nullptr;check(nemo_speech_asr_create(&cfg,&rec));
 auto options=nemo_speech_asr_recognition_options_default();options.language_code="en-US";options.interim_results=true;options.enable_automatic_punctuation=true;
 nemo_speech_asr_stream* stream=nullptr;check(nemo_speech_asr_streaming_recognize(rec,&options,&stream));
 puts("{\"type\":\"ready\"}");fflush(stdout);
 float frame[320];size_t filled=0;
 while(true){auto n=read(STDIN_FILENO,((char*)frame)+filled,sizeof(frame)-filled);if(n<=0)break;filled+=n;if(filled==sizeof(frame)){check(nemo_speech_asr_stream_push_f32(stream,frame,320,16000));drain(stream);filled=0;}}
 if(filled>=4){check(nemo_speech_asr_stream_push_f32(stream,frame,filled/4,16000));drain(stream);}
 check(nemo_speech_asr_stream_finish(stream));drain(stream);nemo_speech_asr_stream_close(stream);nemo_speech_asr_destroy(rec);return 0;
}
