#!/usr/bin/env bash

set -eou pipefail

# fix segmentation fault reported in https://github.com/k2-fsa/icefall/issues/674
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

nj=16
stage=-1
stop_stage=3

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/LibriTTS
#      You can download LibriTTS from https://www.openslr.org/60/
#

dl_dir=$PWD/download

# dataset_parts="-p dev-clean -p test-clean"  # debug
dataset_parts="--dataset-parts all"  # all

model_name="valle"
max_duration=40
use_fp16=true
num_decoder_layers=12

deepspeed=false
deepspeed_config=configs/ds_zero2.config

. shared/parse_options.sh || exit 1


# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  # If you have pre-downloaded it to /path/to/LibriTTS,
  # you can create a symlink
  #
  #   ln -sfv /path/to/LibriTTS $dl_dir/LibriTTS
  #
  if [ ! -d $dl_dir/LibriTTS/dev-other ]; then
    # lhotse download libritts $dl_dir
    lhotse download libritts ${dataset_parts} $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare LibriTTS manifest"
  # We assume that you have downloaded the LibriTTS corpus
  # to $dl_dir/LibriTTS
  mkdir -p data/manifests
  if [ ! -e data/manifests/.libritts.done ]; then
    lhotse prepare libritts ${dataset_parts} -j $nj $dl_dir/LibriTTS data/manifests
    touch data/manifests/.libritts.done
  fi
fi


if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Tokenize LibriTTS"
  mkdir -p data/tokenized
  if [ ! -e data/tokenized/.libritts.tokenize.done ]; then
    python3 bin/tokenizer.py --dataset-parts "${dataset_parts}" \
        --src-dir "data/manifests" \
        --output-dir "data/tokenized"
  fi
  touch data/tokenized/.libritts.tokenize.done
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Prepare LibriTTS train/dev/test"
  if [ ! -e data/tokenized/.libritts.train.done ]; then
    if [ "${dataset_parts}" == "--dataset-parts all" ];then
      # train
      lhotse combine \
        data/tokenized/libritts_cuts_train-clean-100.jsonl.gz \
        data/tokenized/libritts_cuts_train-clean-360.jsonl.gz \
        data/tokenized/libritts_cuts_train-other-500.jsonl.gz \
        data/tokenized/cuts_train.jsonl.gz

      # dev
      lhotse copy \
        data/tokenized/libritts_cuts_dev-clean.jsonl.gz \
        data/tokenized/cuts_dev.jsonl.gz
    else  # debug
      # train
      lhotse copy \
        data/tokenized/libritts_cuts_dev-clean.jsonl.gz \
        data/tokenized/cuts_train.jsonl.gz
      # dev
      lhotse subset --first 400 \
        data/tokenized/libritts_cuts_test-clean.jsonl.gz \
        data/tokenized/cuts_dev.jsonl.gz
    fi

    # test
    lhotse copy \
      data/tokenized/libritts_cuts_test-clean.jsonl.gz \
      data/tokenized/cuts_test.jsonl.gz

    touch data/tokenized/.libritts.train.done
  fi
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Train ${model_name}"

  # same as paper
  if $deepspeed;then
    deepspeed bin/trainer.py --max-duration ${max_duration} --use-fp16 ${use_fp16} \
      --decoder-dim 1024 --nhead 16 --num-decoder-layers ${num_decoder_layers} \
      --deepspeed --deepspeed_config ${deepspeed_config} \
      --model-name "${model_name}" \
      --exp-dir exp/${model_name}_ds_zero2
  else
    python3 bin/trainer.py --max-duration ${max_duration} --use-fp16 ${use_fp16} \
      --decoder-dim 1024 --nhead 16 --num-decoder-layers ${num_decoder_layers} \
      --model-name "${model_name}" \
      --exp-dir exp/${model_name}
  fi
fi
